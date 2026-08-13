--!strict
--[[
	ParkourNetwork.lua

	Owns: the client half of this feature's network surface -- resolving the two Parkour_* remotes,
	firing one small report when a velocity-owning parkour action starts and one when it ends, and
	surfacing a server rejection back to the controller so its state machine can roll back instead of
	silently desyncing.

	WHAT IS AND ISN'T SENT, because this is the whole network cost of the feature: nothing per-frame.
	No position stream, no velocity stream, no state heartbeat. The client simulates locally (which is
	what makes movement feel instant) and tells the server only about the discrete moments where the
	server's own WalkSpeed resolver has to stand down or hand momentum back -- slide, vault, mantle,
	wall-run, wall-jump, ledge climb, roll. Ordinary walking, sprinting, jumping and falling generate
	no traffic at all, because the server already governs those through the combat layer's existing
	WalkSpeed path and has nothing to learn from a report.

	Rate limiting exists on BOTH sides and is not redundant. The server's limiter
	(Server/Systems/ParkourSystem.lua) is the security boundary and assumes nothing about the client.
	The limiter here is a politeness budget: it stops an honest client whose state machine is
	thrashing (a slide entry oscillating against its own exit condition on a slope, say) from
	spending its whole allowance and getting its NEXT, legitimate report dropped -- the same reasoning
	Constants.NetworkBudget.MaxAttackCallsPerSecondPerPlayer's own header gives for splitting attacks
	out of the shared bucket.

	Does not own: deciding when an action starts or ends (the State modules and ParkourController do),
	what a rejection means (ParkourController.OnActionRejected), or any validation -- the server
	re-checks everything sent from here regardless.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local ParkourTypes = require(ReplicatedStorage.Shared.Parkour.ParkourTypes)
local Logger = require(ReplicatedStorage.Shared.Logger)

type ActionKind = ParkourTypes.ActionKind
type ActionPhase = ParkourTypes.ActionPhase
type ActionRejectedPayload = ParkourTypes.ActionRejectedPayload

local logger = Logger.scope("ParkourNetwork")

local ParkourNetwork = {}

local RemoteNames = ParkourConstants.Network.RemoteNames

local reportRemote: RemoteEvent? = nil
-- No local for the rejection remote: it is subscribed to once in Start and never referenced again
-- (this side only ever listens on it, never fires), so holding a reference would be a variable that
-- exists purely to look symmetrical with reportRemote above.
local started = false

local rejectionHandler: ((ActionRejectedPayload) -> ())? = nil

-- Sliding-window send budget. A plain timestamp ring rather than a token bucket so the window
-- matches the server's own RateLimiter semantics (calls within the last second) exactly -- a client
-- budget that measured "rate" differently from the server's would drop reports the server would
-- have accepted, or vice versa.
local sendTimestamps: { number } = {}
-- os.clock() of the last report per action kind, for the per-kind minimum interval that mirrors the
-- server's own DuplicateAction check.
local lastSentPerKind: { [string]: number } = {}

local function withinBudget(now: number, kind: ActionKind): boolean
	local lastSameKind = lastSentPerKind[kind]
	if lastSameKind and (now - lastSameKind) < ParkourConstants.Network.MinSameActionIntervalSeconds then
		return false
	end

	local writeIndex = 1
	for readIndex = 1, #sendTimestamps do
		local timestamp = sendTimestamps[readIndex]
		if (now - timestamp) < 1 then
			sendTimestamps[writeIndex] = timestamp
			writeIndex += 1
		end
	end
	for index = #sendTimestamps, writeIndex, -1 do
		sendTimestamps[index] = nil
	end

	return #sendTimestamps < ParkourConstants.Network.MaxReportsPerSecondPerPlayer
end

-- Fires one report. Returns whether it was actually sent -- the controller uses that to decide
-- whether it may assume the server knows about this action (a dropped Start means the server never
-- granted velocity ownership, so the client must not behave as though it did for anything the
-- server can observe).
local function report(
	kind: ActionKind,
	phase: ActionPhase,
	speed: number,
	position: Vector3,
	durationSeconds: number?
): boolean
	local remote = reportRemote
	if not remote then
		return false
	end
	local now = os.clock()
	if not withinBudget(now, kind) then
		logger:debug("Parkour report dropped by local budget", { kind = kind, phase = phase })
		return false
	end
	table.insert(sendTimestamps, now)
	lastSentPerKind[kind] = now

	remote:FireServer({
		Kind = kind,
		Phase = phase,
		Speed = speed,
		Position = position,
		DurationSeconds = durationSeconds,
	})
	return true
end

function ParkourNetwork.ReportStart(
	kind: ActionKind,
	speed: number,
	position: Vector3,
	durationSeconds: number
): boolean
	return report(kind, "Start", speed, position, durationSeconds)
end

function ParkourNetwork.ReportEnd(kind: ActionKind, speed: number, position: Vector3): boolean
	return report(kind, "End", speed, position, nil)
end

-- Registers the single handler for server rejections. One handler, not a signal with many listeners:
-- exactly one module (ParkourController) is allowed to react to a rejection, because reacting means
-- forcing a state transition and two independent reactors could force two different ones.
function ParkourNetwork.OnRejected(handler: (ActionRejectedPayload) -> ()): ()
	rejectionHandler = handler
end

-- Resolves both remotes. Called from ParkourController.Start, itself called from Main.client.lua's
-- boot sequence -- by which point Server/Systems/ParkourSystem.Init() has long since created them
-- (Main.server.lua runs at server start, well before any client finishes its own Start Menu/Loading/
-- Onboarding gates). NetworkBridge's own WaitForChild-with-timeout covers the pathological slow-boot
-- case regardless.
function ParkourNetwork.Start(): ()
	if started then
		return
	end
	started = true

	reportRemote = NetworkBridge.GetRemoteEvent(RemoteNames.ReportAction)

	local rejected = NetworkBridge.GetRemoteEvent(RemoteNames.ActionRejected)
	rejected.OnClientEvent:Connect(function(payload: unknown)
		-- The server is trusted, but a malformed payload should still not error inside a movement
		-- frame -- degrade to ignoring it, the same tolerance every other client-side payload handler
		-- in this codebase applies.
		if typeof(payload) ~= "table" then
			return
		end
		local handler = rejectionHandler
		if handler then
			handler(payload :: ActionRejectedPayload)
		end
	end)

	logger:info("ParkourNetwork started", { player = Players.LocalPlayer.Name })
end

-- Clears the send budget. Called on character respawn: a fresh life should not inherit the previous
-- one's spent allowance, and its per-kind intervals refer to actions that no longer exist.
function ParkourNetwork.Reset(): ()
	table.clear(sendTimestamps)
	table.clear(lastSentPerKind)
end

return ParkourNetwork
