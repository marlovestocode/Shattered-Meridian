--!strict
--[[
	FlightTuning.lua

	Owns: LIVE, IN-MEMORY tuning of FlightConstants' feel numbers -- a Studio-only dev tool
	(DevMenuSystem.lua's ListFlightTuning/SetFlightTuning/ResetFlightTuning) mirroring
	Server/Combat/HitboxTuning.lua's shape: FlightConstants is read BY REFERENCE every frame
	(Client/Flight/FlightController.lua never snapshots it), so mutating a field here takes effect
	on the very next Heartbeat, including for an admin already mid-flight. Lives under a new
	Server/DevMenu/ folder (mirroring the client's existing Client/DevTools/DevMenu/ folder name) rather than
	Server/Combat/, since HitboxTuning.lua's own placement there is specifically because it tunes
	COMBAT weapon stages -- flight tuning has nothing to do with combat, so colocating it there for
	require-path convenience alone would be exactly the "convenience over modularity"
	software-architecture.md warns against. This module is exactly why FlightConstants was pulled out
	of Shared/Constants.lua into its own Shared/Flight/FlightConstants.lua sibling -- see that file's
	own header.

	Writes are ABSOLUTE (SetField), clamped per field. They used to be a fractional nudge (AdjustField,
	+-1%/+-10% of the current value) because the old panel had only step buttons and FlightConstants'
	fields span degrees, studs/s and unitless multipliers, so no one absolute step fitted them all. The
	rebuilt panel draws a real slider per field over its FIELD_LIMITS range (ListFields carries the
	bounds and the file default), which makes the step-size problem the slider's, not this module's.

	Captures every field's ORIGINAL value once, lazily, on first use -- same "the only backup that
	exists, never written to disk" contract as HitboxTuning.lua's own header: there is no
	persistence, and a satisfying live-tuned value is meant to be copied BY HAND back into
	FlightConstants.lua once found.

	Does not own: authorization/rate-limiting (DevMenuSystem.lua), or deciding what a "reasonable"
	value is beyond basic sanity clamping (FIELD_LIMITS below).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local FlightConstants = require(ReplicatedStorage.Shared.Flight.FlightConstants)
local Types = require(ReplicatedStorage.Shared.Types)

local FlightTuning = {}

-- Stable display order, also doubling as the closed set of tunable field names.
local FIELD_ORDER: { Types.FlightTuningFieldName } = {
	"CruiseSpeed",
	"BoostSpeedMultiplier",
	"Acceleration",
	"BoostAcceleration",
	"Deceleration",
	"VerticalSpeedFraction",
	"MaxBankAngleDegrees",
	"MaxPitchAngleDegrees",
	"BankTurnRateSensitivity",
	"TakeoffBurstUpSpeed",
	"TakeoffBurstForwardSpeed",
	"HoverBobAmplitudeStuds",
	"SoftLandingSpeedThreshold",
	"HardLandingSpeedThreshold",
	"SonicBoomSpeedThreshold",
}

local FIELD_DISPLAY_NAMES: { [string]: string } = {
	CruiseSpeed = "Cruise Speed",
	BoostSpeedMultiplier = "Boost Multiplier",
	Acceleration = "Acceleration",
	BoostAcceleration = "Boost Acceleration",
	Deceleration = "Deceleration",
	VerticalSpeedFraction = "Vertical Speed Fraction",
	MaxBankAngleDegrees = "Max Bank Angle",
	MaxPitchAngleDegrees = "Max Pitch Angle",
	BankTurnRateSensitivity = "Bank Sensitivity",
	TakeoffBurstUpSpeed = "Takeoff Up Burst",
	TakeoffBurstForwardSpeed = "Takeoff Forward Burst",
	HoverBobAmplitudeStuds = "Hover Bob Amplitude",
	SoftLandingSpeedThreshold = "Soft Landing Threshold",
	HardLandingSpeedThreshold = "Hard Landing Threshold",
	SonicBoomSpeedThreshold = "Sonic Boom Threshold",
}

-- Per-field sanity floor/ceiling -- prevents a fat-fingered SetField from driving e.g.
-- MaxBankAngleDegrees past 90 or a threshold to zero/negative. Not a balance opinion, just a floor
-- against a value that reads as broken -- same reasoning as HitboxTuning.lua's own CLAMP_MIN/MAX.
local FIELD_LIMITS: { [string]: { Min: number, Max: number } } = {
	CruiseSpeed = { Min = 5, Max = 300 },
	BoostSpeedMultiplier = { Min = 1, Max = 5 },
	Acceleration = { Min = 5, Max = 500 },
	BoostAcceleration = { Min = 5, Max = 500 },
	Deceleration = { Min = 5, Max = 500 },
	VerticalSpeedFraction = { Min = 0.1, Max = 2 },
	MaxBankAngleDegrees = { Min = 0, Max = 89 },
	MaxPitchAngleDegrees = { Min = 0, Max = 89 },
	BankTurnRateSensitivity = { Min = 0.1, Max = 20 },
	TakeoffBurstUpSpeed = { Min = 0, Max = 100 },
	TakeoffBurstForwardSpeed = { Min = 0, Max = 100 },
	HoverBobAmplitudeStuds = { Min = 0, Max = 5 },
	SoftLandingSpeedThreshold = { Min = 1, Max = 200 },
	HardLandingSpeedThreshold = { Min = 1, Max = 300 },
	SonicBoomSpeedThreshold = { Min = 1, Max = 500 },
}

local defaultsByField: { [string]: number } = {}
local capturedOnce = false

local function ensureDefaultsCaptured(): ()
	if capturedOnce then
		return
	end
	capturedOnce = true
	for _, field in FIELD_ORDER do
		defaultsByField[field] = FlightConstants[field]
	end
end

-- Carries the field's bounds and file default alongside its value, so the admin panel's tuning tab
-- can draw a real slider over the real range and mark where the file's own value sits -- rather than
-- the ±% nudge buttons it used to have, which could never say how far a field could go.
local function toInfo(field: Types.FlightTuningFieldName): Types.FlightTuningInfo
	local limits = FIELD_LIMITS[field]
	return {
		Field = field,
		DisplayName = FIELD_DISPLAY_NAMES[field],
		Value = FlightConstants[field],
		Min = limits.Min,
		Max = limits.Max,
		Default = defaultsByField[field],
	}
end

function FlightTuning.ListFields(): { Types.FlightTuningInfo }
	ensureDefaultsCaptured()
	local result = {}
	for _, field in FIELD_ORDER do
		table.insert(result, toInfo(field))
	end
	return result
end

-- Writes one absolute value, clamped to the field's FIELD_LIMITS. Returns nil for a field outside the
-- curated set or a non-finite value -- DevMenuSystem validates both first; this is defense in depth,
-- and the NaN case matters in particular: a NaN survives math.clamp unchanged (it fails both of the
-- comparisons a clamp is built from) and would permanently poison this SHARED FlightConstants[field]
-- value that every flying client reads by reference.
function FlightTuning.SetField(field: Types.FlightTuningFieldName, value: number): Types.FlightTuningInfo?
	ensureDefaultsCaptured()
	local limits = FIELD_LIMITS[field]
	if not limits then
		return nil
	end
	if value ~= value or value == math.huge or value == -math.huge then
		return nil
	end
	FlightConstants[field] = math.clamp(value, limits.Min, limits.Max)
	return toInfo(field)
end

function FlightTuning.ResetField(field: Types.FlightTuningFieldName): Types.FlightTuningInfo?
	ensureDefaultsCaptured()
	local default = defaultsByField[field]
	if default == nil then
		return nil
	end
	FlightConstants[field] = default
	return toInfo(field)
end

return FlightTuning
