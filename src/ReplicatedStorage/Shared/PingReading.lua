--!strict
--[[
	PingReading.lua

	Owns: what a Player:GetNetworkPing() reading MEANS -- the one place that decides whether it is a round
	trip or one way, and turns a raw reading into both. Shared because both sides read it: the server
	refunds latency (Server/Combat/NetworkLatency.lua and the four combat modules behind it, plus lag-
	compensated hits), and the client times its own predictions against it (AttackInputClient's prediction
	timeout, CombatFeedbackClient's stun mirror).

	THE OPEN QUESTION, IN ONE PLACE. Roblox does not document whether GetNetworkPing is a round trip or one
	way. Staff describe it only as packet latency that should read LOWER than the stats overlay's ping (which
	adds the engine's processing on top); DevForum measurements have suggested it reads about HALF the
	overlay, which would make it one way. This codebase was written assuming a round trip. Before this file,
	that assumption was hand-applied at every call site -- `ping / 2` for a one-way lead in one, `ping` as a
	rewind in another, `2 * ping` as a round trip in a third -- so getting it wrong was wrong in five ways at
	once and fixing it meant finding all five.

	Now it is REPORTS_ROUND_TRIP below and nothing else. Measure it once (Client/DevTools/PingProbe.lua logs
	GetNetworkPing beside the overlay's ping, and their ratio, to the Live Console), set the flag, and every
	refund follows. Default true: today's behaviour, unchanged until the measurement says otherwise.

	Garbage reads as zero (a NaN, a negative, a non-number), here as in NetworkLatency: a refund built on a bad
	reading would move a swing or a parry window by that much, so a bad reading refunds nothing.

	Does not own: fetching the reading (NetworkLatency on the server, the client's own LocalPlayer call), or
	what any caller does with the answer.
]]

local PingReading = {}

-- Whether Player:GetNetworkPing() is a ROUND TRIP (true) or ONE WAY (false). See this file's header -- the
-- one line to change once the probe has been run.
PingReading.REPORTS_ROUND_TRIP = true

local function clean(reading: unknown): number
	if typeof(reading) ~= "number" or reading ~= reading or reading < 0 or reading == math.huge then
		return 0
	end
	return reading :: number
end

-- Seconds for a packet to go there and back, from a GetNetworkPing reading.
function PingReading.RoundTrip(reading: unknown): number
	local value = clean(reading)
	return if PingReading.REPORTS_ROUND_TRIP then value else value * 2
end

-- Seconds for a packet to go one way, from a GetNetworkPing reading.
function PingReading.OneWay(reading: unknown): number
	local value = clean(reading)
	return if PingReading.REPORTS_ROUND_TRIP then value / 2 else value
end

return PingReading
