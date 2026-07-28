--!strict
--[[
	FlightTuning.lua

	Owns: LIVE, IN-MEMORY tuning of Constants.Flight's feel numbers -- a Studio-only dev tool
	(DevMenuSystem.lua's ListFlightTuning/AdjustFlightTuning/ResetFlightTuning) mirroring
	Server/Combat/HitboxTuning.lua's shape: Constants.Flight is read BY REFERENCE every frame
	(Client/DevMenu/FlightController.lua never snapshots it), so mutating a field here takes effect
	on the very next Heartbeat, including for an admin already mid-flight. Lives under a new
	Server/DevMenu/ folder (mirroring the client's existing Client/DevMenu/ folder name) rather than
	Server/Combat/, since HitboxTuning.lua's own placement there is specifically because it tunes
	COMBAT weapon stages -- flight tuning has nothing to do with combat, so colocating it there for
	require-path convenience alone would be exactly the "convenience over modularity"
	software-architecture.md warns against.

	Deviation from HitboxTuning.lua: AdjustField takes a FRACTIONAL delta (e.g. 0.1 = +10% of the
	field's CURRENT value), not an absolute delta -- Constants.Flight's fields span degrees, studs/s,
	studs/s^2, and unitless multipliers, so one fixed absolute step size can't sensibly apply to all
	of them the way HitboxTuning's seconds-only fields could share one.

	Captures every field's ORIGINAL value once, lazily, on first use -- same "the only backup that
	exists, never written to disk" contract as HitboxTuning.lua's own header: there is no
	persistence, and a satisfying live-tuned value is meant to be copied BY HAND back into
	Constants.lua once found.

	Does not own: authorization/rate-limiting (DevMenuSystem.lua), or deciding what a "reasonable"
	value is beyond basic sanity clamping (FIELD_LIMITS below).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage.Shared.Constants)
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

-- Per-field sanity floor/ceiling -- prevents a fat-fingered/spammed AdjustField from driving e.g.
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
		defaultsByField[field] = Constants.Flight[field]
	end
end

local function toInfo(field: Types.FlightTuningFieldName): Types.FlightTuningInfo
	return { Field = field, DisplayName = FIELD_DISPLAY_NAMES[field], Value = Constants.Flight[field] }
end

function FlightTuning.ListFields(): { Types.FlightTuningInfo }
	ensureDefaultsCaptured()
	local result = {}
	for _, field in FIELD_ORDER do
		table.insert(result, toInfo(field))
	end
	return result
end

-- deltaFraction: e.g. 0.1 nudges the field UP by 10% of its current value, -0.1 nudges it DOWN by
-- 10%. Clamped to FIELD_LIMITS after applying. Returns nil for a field name outside FIELD_LIMITS
-- (the caller, DevMenuSystem.lua, already validates against a closed whitelist before calling this,
-- so that should never happen in practice -- this is defense in depth, not the primary gate).
function FlightTuning.AdjustField(field: Types.FlightTuningFieldName, deltaFraction: number): Types.FlightTuningInfo?
	ensureDefaultsCaptured()
	local limits = FIELD_LIMITS[field]
	if not limits then
		return nil
	end
	local current = Constants.Flight[field]
	local updated = math.clamp(current * (1 + deltaFraction), limits.Min, limits.Max)
	Constants.Flight[field] = updated
	return toInfo(field)
end

function FlightTuning.ResetField(field: Types.FlightTuningFieldName): Types.FlightTuningInfo?
	ensureDefaultsCaptured()
	local default = defaultsByField[field]
	if default == nil then
		return nil
	end
	Constants.Flight[field] = default
	return toInfo(field)
end

return FlightTuning
