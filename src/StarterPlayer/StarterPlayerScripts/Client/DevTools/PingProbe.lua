--!strict
--[[
	PingProbe.lua

	Owns: answering Shared/PingReading.lua's open question -- is Player:GetNetworkPing() a round trip or one
	way? -- by measuring it, once, in Studio.

	HOW IT TELLS. The stats overlay's "Data Ping" (Stats.Network.ServerStatsItem) is a round trip in
	milliseconds. Every SAMPLE_SECONDS for PROBE_SECONDS this logs both, and the ratio GetNetworkPing /
	overlay, to the Live Console (F5, search "PingProbe"); at the end it logs the median ratio and the verdict:

	    ratio near 1.0   GetNetworkPing is a ROUND TRIP  -> PingReading.REPORTS_ROUND_TRIP = true (as shipped)
	    ratio near 0.5   GetNetworkPing is ONE WAY       -> set PingReading.REPORTS_ROUND_TRIP = false

	Roblox staff say the overlay also counts the engine's processing, so a round-trip GetNetworkPing still
	reads somewhat LOWER than it; the verdict's split is at 0.7 for that reason. Run it with Studio's Network
	Simulator set to a real latency (100-200 ms): at zero ping both numbers are noise.

	STUDIO ONLY, and passive: it starts with the dev tools, reads two numbers, and logs. It changes nothing.
	Lives under DevTools, so a live.project.json build does not ship it.

	Does not own: the flag (PingReading), or anything that uses latency.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")

local Logger = require(ReplicatedStorage.Shared.Logger)
local PingReading = require(ReplicatedStorage.Shared.PingReading)

local logger = Logger.scope("PingProbe")

local PingProbe = {}

local SAMPLE_SECONDS = 2
local PROBE_SECONDS = 60
-- Below this a round-trip GetNetworkPing is implausible even allowing for the overlay's processing time.
local ROUND_TRIP_FLOOR = 0.7
-- Overlay pings under this are too small to divide by meaningfully.
local MIN_OVERLAY_MS = 20

local started = false

local function overlayPingMs(): number?
	local ok, value = pcall(function()
		return (Stats :: any).Network.ServerStatsItem["Data Ping"]:GetValue()
	end)
	return if ok and typeof(value) == "number" then value else nil
end

-- The verdict for a list of ratios: their median, and which way it points. Pure, for its spec.
function PingProbe.Verdict(ratios: { number }): (number?, boolean?)
	if #ratios == 0 then
		return nil, nil
	end
	local sorted = table.clone(ratios)
	table.sort(sorted)
	local middle = #sorted // 2
	local median = if #sorted % 2 == 1 then sorted[middle + 1] else (sorted[middle] + sorted[middle + 1]) / 2
	return median, median >= ROUND_TRIP_FLOOR
end

function PingProbe.Start(): ()
	if started or not RunService:IsStudio() then
		return
	end
	started = true
	task.spawn(function()
		local ratios: { number } = {}
		local deadline = os.clock() + PROBE_SECONDS
		while os.clock() < deadline do
			task.wait(SAMPLE_SECONDS)
			local reading = Players.LocalPlayer:GetNetworkPing() * 1000
			local overlay = overlayPingMs()
			if overlay and overlay >= MIN_OVERLAY_MS then
				table.insert(ratios, reading / overlay)
				logger:debug("sample", {
					getNetworkPingMs = math.floor(reading + 0.5),
					overlayPingMs = math.floor(overlay + 0.5),
					ratio = string.format("%.2f", reading / overlay),
				})
			end
		end
		local median, roundTrip = PingProbe.Verdict(ratios)
		if median == nil then
			logger:info(
				"no usable samples -- run with Studio's Network Simulator at 100-200 ms of latency",
				{ minOverlayMs = MIN_OVERLAY_MS }
			)
			return
		end
		logger:info(if roundTrip then "GetNetworkPing reads as a ROUND TRIP" else "GetNetworkPing reads as ONE WAY", {
			medianRatio = string.format("%.2f", median),
			samples = #ratios,
			flagNow = PingReading.REPORTS_ROUND_TRIP,
			setFlagTo = roundTrip,
			matches = roundTrip == PingReading.REPORTS_ROUND_TRIP,
		})
	end)
end

return PingProbe
