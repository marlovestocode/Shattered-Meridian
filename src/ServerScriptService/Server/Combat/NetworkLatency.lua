--!strict
--[[
	NetworkLatency.lua

	Owns: the one answer to "how much network latency does this combatant have", in seconds -- as a round
	trip (PingSeconds / RoundTripSeconds) or one way (OneWaySeconds). Zero for anything that is not a
	player's character -- a training bot or a dummy has no connection to refund.

	WHAT A READING MEANS is Shared/PingReading.lua's call, not this file's (2026-10-07): whether
	GetNetworkPing is itself a round trip or one way is undocumented, so it is one flag there, and both
	answers here are derived from it. A caller asks for the quantity it means -- a lead is one way, a window
	that must cover a press's trip and its answer's is a round trip -- and never halves or doubles a reading
	itself.

	Four combat modules refund latency: the parry rewind (DefenseSystem), the air combo's rewound swing
	deadline (AirComboSystem), the environment reactions (EnvironmentReactionSystem) and the attack layer's
	swing lead (AttackRequestSystem, AttackConstants.Latency). The first three each carried a hand-copied
	lookup with the same pcall and the same sanity checks; the fourth would have been the fourth copy.

	GetNetworkPing is pcall'd and its answer sanity-checked because a refund built on a NaN or a negative
	number would move a swing or a parry window by that much. Garbage reads as zero: no refund, never a
	wrong one.

	Does not own: what any caller does with the number -- each one caps and halves it to its own rule.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PingReading = require(ReplicatedStorage.Shared.PingReading)

local NetworkLatency = {}

-- Spec-only replacement for the lookup (SetResolver): it stands in for the raw GetNetworkPing READING. A
-- dummy has no Player and so no ping, which would leave every latency rule untestable without a live client.
local resolver: ((model: Model) -> number)? = nil

-- The raw GetNetworkPing reading for a player-backed model; 0 for anything else, or for a bad read.
local function readingOf(model: Model): number
	local override = resolver
	if override then
		return override(model)
	end
	local player = Players:GetPlayerFromCharacter(model)
	if not player then
		return 0
	end
	local ok, ping = pcall(function()
		return player:GetNetworkPing()
	end)
	return if ok then ping else 0
end

-- Round-trip latency for a player-backed model, in seconds; 0 for anything else.
function NetworkLatency.RoundTripSeconds(model: Model): number
	return PingReading.RoundTrip(readingOf(model))
end

-- One-way latency for a player-backed model, in seconds; 0 for anything else.
function NetworkLatency.OneWaySeconds(model: Model): number
	return PingReading.OneWay(readingOf(model))
end

-- The round trip, under the name its first four callers use.
NetworkLatency.PingSeconds = NetworkLatency.RoundTripSeconds

-- Spec-only. Replaces the lookup for every caller of PingSeconds; nil restores the real one.
function NetworkLatency.SetResolver(fn: ((model: Model) -> number)?): ()
	resolver = fn
end

return NetworkLatency
