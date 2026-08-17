--!strict
--[[
	ParryWindows.lua

	Owns: where a parry window's timing comes from. The single answer to "how long is this parry live
	for", and the reason no such number appears in DefenseConstants.lua.

	THE AUTHORITY IS THE ANIMATION. An animator places ParryStart and ParryClose markers on
	the parry clip's keyframes, and those two times ARE the window. Retiming a parry is retiming the
	animation and nothing else -- no constant to find, no second place to keep in sync, and the visual
	and the mechanic cannot drift apart because they are the same data.

	WHY THE ASSET, NOT THE TRACK. The obvious reading of "use the animation's events" is to play the
	track and listen on GetMarkerReachedSignal. That is right on the CLIENT, where the markers drive
	presentation, and wrong for the authority, for three reasons:
	  1. The server would have to play the track to hear it, making the authoritative window's start
	     depend on animation replication rather than on the input arriving.
	  2. If the track is interrupted -- a hit reaction, a respawn, the parkour framework taking the
	     body -- ParryClose silently never fires. A window that opens and never closes is a
	     permanent parry, and it fails in the direction that rewards the bug.
	  3. It makes the window untestable without playing real animations in real time.
	Constants.Run.Footsteps already recorded this caution ("only as reliable as the authored markers in
	whatever clip is currently playing"). This module answers it rather than ignoring it: it reads the
	authored KeyframeSequence without playing anything, and runs its own timer off those numbers.

	GET NEVER YIELDS. Extraction does (GetKeyframeSequenceAsync is a web call and is rate limited), so
	the two are separate calls: Prefetch does the yielding work, Get is a pure cache read. A block
	press must resolve on the frame it arrives -- a Get that could yield mid-press would make the
	system's own input path depend on a web request, which is precisely the fragility this file exists
	to avoid. ValidateAll at boot is what makes the cache warm by the time anyone presses.

	THREE SOURCES, STRICT PRECEDENCE, NO FALLBACK:
	  1. Override    -- Studio only, for live tuning. Never reachable in a shipped server.
	  2. Markers     -- the authored asset. The end state, and the authority whenever present.
	  3. Registered  -- an explicit in-code declaration, per id, written by hand.
	An id with none of the three returns nil and THE PARRY IS NOT ARMED. There is deliberately no
	default window: a default is the hardcoded value this system exists to remove, and substituting
	one silently turns "someone forgot a marker" into "this move's parry has been subtly wrong for a
	month."

	A registration is not a default. It is per-id, hand-written and greppable -- the three properties
	the forbidden fallback lacks -- and it exists because there are no parry clips yet at all, so
	strict marker-only would mean building a system whose central mechanic can never fire. ValidateAll
	reports registrations that markers have shadowed, so the dead ones are loud once the real assets
	land.

	Does not own: what a window MEANS (DefenseStateMachine drives it), the recovery fallback
	(DefenseConstants.Parry.RecoverySeconds), or any playback (Client/Defense/DefenseClient.lua).
]]

local KeyframeSequenceProvider = game:GetService("KeyframeSequenceProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local DefenseConstants = require(ReplicatedStorage.Shared.Defense.DefenseConstants)
local DefenseTypes = require(ReplicatedStorage.Shared.Defense.DefenseTypes)
local Logger = require(ReplicatedStorage.Shared.Logger)

type ParryWindow = DefenseTypes.ParryWindow

local logger = Logger.scope("ParryWindows")

local ParryWindows = {}

-- The three marker names. Open and Close are required as a PAIR -- one without the other is a
-- half-authored window and is refused rather than half-honoured. RecoveryEnd is optional and falls
-- back to DefenseConstants.Parry.RecoverySeconds (a punish length, not a window -- see that
-- constant's own header for why a fallback is legitimate there and nowhere else).
local MARKER_OPEN = "ParryStart"
local MARKER_CLOSE = "ParryClose"
local MARKER_RECOVERY_END = "ParryRecoveryEnd"

-- How many times a failed extraction is retried before the id is negatively cached forever. Bounded
-- because GetKeyframeSequenceAsync is rate limited: an id that is simply wrong would otherwise be
-- re-requested on every press for the rest of the session, spending the budget that the ids which DO
-- resolve need.
local MAX_EXTRACTION_ATTEMPTS = 3
local RETRY_BASE_SECONDS = 0.5

-- Successfully resolved windows, by animation id. Also holds `false` for an id whose extraction
-- failed its last attempt -- the negative cache, distinguished from "never asked" (nil) so a
-- permanent failure is never retried and a fresh id still can be.
local markerCache: { [string]: ParryWindow | false } = {}
-- Ids with an extraction in flight, so concurrent Prefetch calls for the same id await the one
-- request rather than each starting their own.
local inFlight: { [string]: boolean } = {}

local registered: { [string]: ParryWindow } = {}
local overrides: { [string]: ParryWindow } = {}

-- Swappable so specs can drive extraction without a published asset. Returns the authored sequence,
-- or nil if it could not be fetched. Never called on the Get path -- see this file's header.
local extractor: (animationId: string) -> KeyframeSequence? = function(animationId: string): KeyframeSequence?
	local ok, result = pcall(function()
		return KeyframeSequenceProvider:GetKeyframeSequenceAsync(animationId)
	end)
	if not ok then
		return nil
	end
	if typeof(result) ~= "Instance" or not result:IsA("KeyframeSequence") then
		return nil
	end
	return result
end

-- Validation ---------------------------------------------------------------------------------------

-- Whether a candidate window is usable. A window whose Close does not come strictly after its Open is
-- not a short window, it is a broken one, and honouring it would produce a parry that is either
-- instantaneous or inverted. Negative times are refused for the same reason -- an offset before the
-- start of the clip describes nothing.
local function isSane(open: number, close: number, recoveryEnd: number): (boolean, string?)
	if open ~= open or close ~= close or recoveryEnd ~= recoveryEnd then
		return false, "NaN"
	end
	if open < 0 then
		return false, "NegativeOpen"
	end
	if close <= open then
		return false, "CloseNotAfterOpen"
	end
	if recoveryEnd < close then
		return false, "RecoveryBeforeClose"
	end
	return true, nil
end

local function buildWindow(
	open: number,
	close: number,
	recoveryEnd: number?,
	source: "Markers" | "Registered" | "Override"
): (ParryWindow?, string?)
	-- Resolved before the sanity check, so a nil RecoveryEnd is validated as the value that will
	-- actually be used rather than skipped and then substituted behind the check's back.
	local resolvedRecovery = recoveryEnd or (close + DefenseConstants.Parry.RecoverySeconds)
	local ok, reason = isSane(open, close, resolvedRecovery)
	if not ok then
		return nil, reason
	end
	return {
		Open = open,
		Close = close,
		RecoveryEnd = resolvedRecovery,
		Source = source,
	}, nil
end

-- Extraction ---------------------------------------------------------------------------------------

-- Pulls marker times out of an authored sequence. Pure over the Instance tree it is handed -- no web
-- call, no cache, no yielding -- so a spec can build a KeyframeSequence with Instance.new and call
-- this directly, which is exactly what ParryWindows.spec does.
--
-- A marker's time is its KEYFRAME's time; KeyframeMarker itself carries no time of its own. Duplicate
-- markers of the same name take the EARLIEST keyframe: an animator who left two ParryStart
-- markers on a clip meant the first one, and picking the later one silently shortens the window.
--
-- Keyframe.Time is a FLOAT32, so a marker authored at 0.05 comes back as 0.05000000074505806. That
-- is far below any timing anyone can perceive and nothing here rounds it, but it does mean marker
-- times must never be compared for exact equality -- against an authored number, or against each
-- other.
function ParryWindows.ExtractMarkers(sequence: KeyframeSequence): { [string]: number }
	local times: { [string]: number } = {}
	for _, child in sequence:GetChildren() do
		if not child:IsA("Keyframe") then
			continue
		end
		local keyframeTime = child.Time
		for _, marker in child:GetChildren() do
			if not marker:IsA("KeyframeMarker") then
				continue
			end
			local existing = times[marker.Name]
			if existing == nil or keyframeTime < existing then
				times[marker.Name] = keyframeTime
			end
		end
	end
	return times
end

-- Turns an extracted marker map into a window, or nil with a reason. Split from ExtractMarkers so the
-- "which markers are required" rule is stated in one place and testable without an Instance at all.
function ParryWindows.WindowFromMarkers(times: { [string]: number }): (ParryWindow?, string?)
	local open = times[MARKER_OPEN]
	local close = times[MARKER_CLOSE]
	if open == nil and close == nil then
		return nil, "NoMarkers"
	end
	if open == nil then
		return nil, "MissingOpen"
	end
	if close == nil then
		return nil, "MissingClose"
	end
	return buildWindow(open, close, times[MARKER_RECOVERY_END], "Markers")
end

-- Fetches and caches an id's authored window. YIELDS. Safe to call concurrently for the same id --
-- the second caller waits on the first's request rather than starting another.
--
-- Returns true if the id now has an authored window cached. A false return is not necessarily a
-- problem: an id with a registration is perfectly playable without markers, which is what ValidateAll
-- distinguishes.
function ParryWindows.Prefetch(animationId: string): boolean
	local cached = markerCache[animationId]
	if cached ~= nil then
		return cached ~= false
	end

	if inFlight[animationId] then
		-- Another coroutine is already fetching this id. Wait for it to settle rather than issuing a
		-- second request against a rate-limited endpoint.
		while inFlight[animationId] do
			task.wait()
		end
		local settled = markerCache[animationId]
		return settled ~= nil and settled ~= false
	end

	inFlight[animationId] = true
	local resolved: ParryWindow | false = false
	for attempt = 1, MAX_EXTRACTION_ATTEMPTS do
		local sequence = extractor(animationId)
		if sequence then
			local window, reason = ParryWindows.WindowFromMarkers(ParryWindows.ExtractMarkers(sequence))
			if window then
				resolved = window
			else
				-- The asset resolved but does not carry a usable pair. Retrying cannot change that, so
				-- this breaks rather than spending the remaining attempts on a settled answer.
				logger:warn("Parry animation has no usable window markers", {
					animationId = animationId,
					reason = reason,
				})
			end
			break
		end
		if attempt < MAX_EXTRACTION_ATTEMPTS then
			-- Backoff, because the overwhelmingly likely cause of a failed fetch is the rate limit,
			-- and an immediate retry is the one thing guaranteed to hit it again.
			task.wait(RETRY_BASE_SECONDS * attempt)
		end
	end

	-- Written before clearing the in-flight flag, so a waiter that wakes on the flag always sees the
	-- settled value rather than racing the write.
	markerCache[animationId] = resolved
	inFlight[animationId] = nil
	return resolved ~= false
end

-- Registration -------------------------------------------------------------------------------------

-- Declares a window in code, for an id whose asset carries no markers. See this file's header for why
-- this is not the forbidden default.
--
-- Refused (and logged) rather than silently coerced if the numbers do not describe a real window --
-- the same treatment a badly authored asset gets, since a bad registration is the same mistake made
-- somewhere else.
function ParryWindows.Register(animationId: string, open: number, close: number, recoveryEnd: number?): boolean
	local window, reason = buildWindow(open, close, recoveryEnd, "Registered")
	if not window then
		logger:warn("Refused a parry window registration", {
			animationId = animationId,
			reason = reason,
		})
		return false
	end
	registered[animationId] = window
	return true
end

-- Studio-only live tuning, for the dev menu. Gated so it cannot ship as an accidental authority: on a
-- real server this is a no-op that says so.
function ParryWindows.Override(animationId: string, open: number, close: number, recoveryEnd: number?): boolean
	if not RunService:IsStudio() then
		logger:warn("ParryWindows.Override refused outside Studio", { animationId = animationId })
		return false
	end
	local window, reason = buildWindow(open, close, recoveryEnd, "Override")
	if not window then
		logger:warn("Refused a parry window override", { animationId = animationId, reason = reason })
		return false
	end
	overrides[animationId] = window
	return true
end

function ParryWindows.ClearOverride(animationId: string): ()
	overrides[animationId] = nil
end

-- Lookup -------------------------------------------------------------------------------------------

-- The window for an id, or nil if it has none. NEVER YIELDS -- see this file's header. An id that has
-- not been prefetched reads as having no markers, which is why ValidateAll runs at boot.
function ParryWindows.Get(animationId: string): ParryWindow?
	local override = overrides[animationId]
	if override then
		return override
	end
	local cached = markerCache[animationId]
	if cached ~= nil and cached ~= false then
		return cached
	end
	return registered[animationId]
end

-- Whether a parry can be armed for this id at all. The one question DefenseSystem asks.
function ParryWindows.IsArmed(animationId: string): boolean
	return ParryWindows.Get(animationId) ~= nil
end

-- Latency refund. Returns the time at which the window stops counting as a PARRY for hit
-- classification -- which is not the same as when Blocking begins.
--
-- ParryClose does two jobs: it ends the parry and it starts the block. Adding ping to it
-- naively would push a high-ping player's guard UP LATER, charging them for the latency this is
-- supposed to refund. So the marker yields two derived times: this one, extended; and the Blocking
-- transition, left at Close exactly. The compensation is then strictly a refund and never a cost,
-- which is the only shape in which it is defensible.
--
-- Bots and dummies pass 0 and get nothing, having no latency to refund.
function ParryWindows.ParryEndFor(window: ParryWindow, pingSeconds: number): number
	if pingSeconds ~= pingSeconds or pingSeconds <= 0 then
		return window.Close
	end
	return window.Close + math.min(pingSeconds, DefenseConstants.Parry.PingCompensationMaxSeconds)
end

-- Boot ---------------------------------------------------------------------------------------------

export type ValidationRecord = {
	AnimationId: string,
	HasMarkers: boolean,
	HasRegistration: boolean,
	-- True when a registration exists but authored markers won. The registration is dead weight and
	-- should be deleted -- reported rather than silently ignored, so the end state is reached
	-- deliberately rather than by accident.
	RegistrationShadowed: boolean,
	Armed: boolean,
}

-- Warms the cache for every id this system might arm, and reports what it found. YIELDS -- call it
-- from Init, not from a hot path.
--
-- A missing window becomes a startup warning rather than a mid-fight mystery, which is the entire
-- reason fail-closed is survivable as a design.
function ParryWindows.ValidateAll(animationIds: { string }): { ValidationRecord }
	local records: { ValidationRecord } = {}
	for _, animationId in animationIds do
		local hasMarkers = ParryWindows.Prefetch(animationId)
		local hasRegistration = registered[animationId] ~= nil
		local record: ValidationRecord = {
			AnimationId = animationId,
			HasMarkers = hasMarkers,
			HasRegistration = hasRegistration,
			RegistrationShadowed = hasMarkers and hasRegistration,
			Armed = ParryWindows.IsArmed(animationId),
		}
		table.insert(records, record)

		if not record.Armed then
			logger:warn("No parry window for animation -- the parry will NOT arm for it", {
				animationId = animationId,
			})
		elseif record.RegistrationShadowed then
			logger:info("Authored markers now shadow a parry window registration -- the registration can be deleted", {
				animationId = animationId,
			})
		end
	end
	return records
end

-- Testing ------------------------------------------------------------------------------------------

-- Swaps the extractor. Spec-only; the shipped code never calls it.
function ParryWindows.SetExtractor(nextExtractor: (animationId: string) -> KeyframeSequence?): ()
	extractor = nextExtractor
end

-- Drops every cache and declaration. Spec-only, so one case cannot serve another its windows.
function ParryWindows.Reset(): ()
	table.clear(markerCache)
	table.clear(inFlight)
	table.clear(registered)
	table.clear(overrides)
end

return ParryWindows
