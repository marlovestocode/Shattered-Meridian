--!strict
--[[
	NetworkLatency.lua

	Owns: the one answer to "how much network latency does this combatant have", in seconds, as
	Player:GetNetworkPing reports it (a ROUND TRIP). Zero for anything that is not a player's character --
	a training bot or a dummy has no connection to refund.

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

local NetworkLatency = {}

-- Spec-only replacement for the lookup (SetResolver). A dummy has no Player and so no ping, which would
-- leave every latency rule untestable without a live client.
local resolver: ((model: Model) -> number)? = nil

-- Round-trip latency for a player-backed model, in seconds; 0 for anything else.
function NetworkLatency.PingSeconds(model: Model): number
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
	if not ok or typeof(ping) ~= "number" or ping ~= ping or ping < 0 then
		return 0
	end
	return ping
end

-- Spec-only. Replaces the lookup for every caller of PingSeconds; nil restores the real one.
function NetworkLatency.SetResolver(fn: ((model: Model) -> number)?): ()
	resolver = fn
end

return NetworkLatency
