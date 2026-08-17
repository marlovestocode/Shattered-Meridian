--!strict
--[[
	AttackWindows.lua

	Owns: an OPTIONAL marker-driven override for a Basic-string (M1) swing's WindupSeconds -- the
	moment the hitbox becomes live, read off the swing clip's own authored KeyframeSequence instead of
	the hand-typed Constants.lua number, when (and only when) a usable marker is actually there.

	FAIL-SOFT, UNLIKE Shared/Defense/ParryWindows.lua -- read that module's header first, since this
	one borrows its entire extraction mechanism (read the authored KeyframeSequence directly via
	KeyframeSequenceProvider, never play the track -- the same three reasons apply here verbatim: the
	server would have to play the track to hear it, an interrupted track would strand the read, and it
	would be untestable without a live Animator). The difference is what a MISSING marker means. Parry
	is an optional mechanic: no markers, no parry, and that is a safe and correct default. A Basic
	swing's hit timing is not optional -- every M1 press must still deal damage on schedule even if an
	animator never touched a clip's markers, so absence here means "keep the hardcoded
	Constants.Combat.Weapons[...].Stages.Basic[n].WindupSeconds," never "this move does not work."

	THE MARKER NAME IS DERIVED FROM THE MOVE, not looked up per id: a Basic-string MoveId always has
	the shape "default:<WeaponId>:Basic:<stage>" (DefaultMoveRegistry's own scheme, restated here the
	same way SwingSequencer/AttackCatalog already restate it elsewhere in this codebase), and the
	expected marker on that stage's clip is "AttackM<stage>" -- AttackM1 on the first Basic clip,
	AttackM2 on the second, AttackM3 on the third. One marker per clip, not a pair: it marks the single
	instant the swing connects, which is exactly what WindupSeconds already means (see
	Constants.Combat.Weapons.Primary.Stages.Basic[1].WindupSeconds' own comment -- 0.31, "confirmed via
	live Studio playtest... that all three M1 stages read as landing on-swing at this value"). This
	module lets that number come from the asset instead of a human re-confirming it by hand every time
	the clip changes.

	Heavy and Finisher are OUT OF SCOPE -- WindupOverride returns nil for any MoveId that is not a
	Basic-string stage, unconditionally, so those keep their pure hand-typed timing.

	AttackConstants.Windows.Enabled is the one setting that turns this whole mechanism off -- false
	makes WindupOverride always return nil, the same as if no clip had ever carried a marker, for a
	live server that needs to rule this out as a suspect without a code change.

	Does not own: the sanity bound applied once a value comes back (AttackCatalog.Get, the one runtime
	caller, additionally rejects an override that would blow past the move's own authored total
	timeline before applying it -- see that function's own comment for why), or any playback
	(Client/Combat/AttackInputClient.lua plays whatever clip AttackCatalog hands it, unaware this
	module exists at all).
]]

local KeyframeSequenceProvider = game:GetService("KeyframeSequenceProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AttackConstants = require(ReplicatedStorage.Shared.Attack.AttackConstants)
local Logger = require(ReplicatedStorage.Shared.Logger)

local logger = Logger.scope("AttackWindows")

local AttackWindows = {}

-- Successfully resolved marker times, keyed by "animationId|markerName" -- a marker name only means
-- anything against the clip it was extracted from, so the cache key is the pair, not either alone.
-- Also holds `false` for a lookup whose extraction failed its last attempt -- the negative cache,
-- distinguished from "never asked" (nil) the same way ParryWindows.markerCache is, and for the same
-- reason: a permanent failure is never retried, a fresh id still can be.
local markerCache: { [string]: number | false } = {}
-- Keys with an extraction in flight, so concurrent Prefetch calls for the same pair await the one
-- request rather than each starting their own.
local inFlight: { [string]: boolean } = {}

-- How many times a failed extraction is retried before the pair is negatively cached forever --
-- identical budget to ParryWindows, for the identical reason (GetKeyframeSequenceAsync is rate
-- limited, and an id that is simply wrong should not keep spending it).
local MAX_EXTRACTION_ATTEMPTS = 3
local RETRY_BASE_SECONDS = 0.5

-- Swappable so specs can drive extraction without a published asset -- same seam, same contract as
-- ParryWindows.extractor. Never called on the WindupOverride path -- see this file's header.
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

local function cacheKey(animationId: string, markerName: string): string
	return animationId .. "|" .. markerName
end

-- Pulls one marker's time out of an authored sequence -- the earliest keyframe carrying it, same
-- "duplicate markers take the earliest" rule ParryWindows.ExtractMarkers documents and for the same
-- reason (an animator who left two copies meant the first one). Pure over the Instance tree handed
-- in, so a spec can build one with Instance.new and call this directly, no web call involved.
function AttackWindows.ExtractMarkerTime(sequence: KeyframeSequence, markerName: string): number?
	local earliest: number? = nil
	for _, child in sequence:GetChildren() do
		if not child:IsA("Keyframe") then
			continue
		end
		local keyframeTime = child.Time
		for _, marker in child:GetChildren() do
			if marker:IsA("KeyframeMarker") and marker.Name == markerName then
				if earliest == nil or keyframeTime < earliest then
					earliest = keyframeTime
				end
			end
		end
	end
	return earliest
end

-- Every KeyframeMarker name actually present on `sequence`, deduped and sorted -- diagnostic only,
-- so a "no usable marker" log can say what WAS found instead of just what wasn't, and a typo/wrong-
-- stage marker name shows up immediately instead of reading as "no marker at all."
local function markerNamesOn(sequence: KeyframeSequence): string
	local seen: { [string]: boolean } = {}
	for _, child in sequence:GetChildren() do
		if not child:IsA("Keyframe") then
			continue
		end
		for _, marker in child:GetChildren() do
			if marker:IsA("KeyframeMarker") then
				seen[marker.Name] = true
			end
		end
	end
	local names = {}
	for name in seen do
		table.insert(names, name)
	end
	table.sort(names)
	return if #names > 0 then table.concat(names, ", ") else "<none>"
end

-- The Basic-string marker name for `moveId`, or nil if it is not shaped like one -- see this file's
-- header for the scheme. Heavy/Finisher/custom moves never match, which is what keeps them out of
-- scope without a second flag anywhere else.
function AttackWindows.MarkerNameFor(moveId: string): string?
	local stage = string.match(moveId, "^default:%a+:Basic:(%d+)$")
	if not stage then
		return nil
	end
	return "AttackM" .. stage
end

-- Fetches and caches ONE (animationId, markerName) pair's time. YIELDS (GetKeyframeSequenceAsync is a
-- web call). Safe to call concurrently for the same pair -- the second caller waits on the first's
-- request rather than starting another, the identical shape ParryWindows.Prefetch uses.
--
-- Returns true if a usable marker is now cached for this pair. A false return is not necessarily a
-- problem -- see this file's header on why absence here means "hardcoded fallback," not "broken."
function AttackWindows.Prefetch(animationId: string, markerName: string): boolean
	local key = cacheKey(animationId, markerName)
	local cached = markerCache[key]
	if cached ~= nil then
		return cached ~= false
	end

	if inFlight[key] then
		while inFlight[key] do
			task.wait()
		end
		local settled = markerCache[key]
		return settled ~= nil and settled ~= false
	end

	inFlight[key] = true
	local resolved: number | false = false
	for attempt = 1, MAX_EXTRACTION_ATTEMPTS do
		local sequence = extractor(animationId)
		if sequence then
			local markerTime = AttackWindows.ExtractMarkerTime(sequence, markerName)
			-- NaN-safe and non-negative -- a marker authored before the clip's own start describes
			-- nothing, the same floor ParryWindows.isSane holds its own Open time to.
			if markerTime ~= nil and markerTime == markerTime and markerTime >= 0 then
				resolved = markerTime
			else
				logger:debug(
					"Attack clip has no usable marker -- keeping the hardcoded WindupSeconds",
					{ animationId = animationId, markerName = markerName, foundMarkers = markerNamesOn(sequence) }
				)
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
	markerCache[key] = resolved
	inFlight[key] = nil
	return resolved ~= false
end

-- The cached WindupSeconds override for `moveId`/`animationId`, or nil -- NEVER YIELDS, same contract
-- as ParryWindows.Get. Returns nil unconditionally while AttackConstants.Windows.Enabled is false,
-- for a MoveId that is not a Basic stage, for a blank animationId, or for a pair that was never
-- prefetched (or whose extraction found nothing usable) -- every one of those means "the caller keeps
-- whatever hardcoded value it already had," never an error.
function AttackWindows.WindupOverride(moveId: string, animationId: string): number?
	if not AttackConstants.Windows.Enabled then
		return nil
	end
	if typeof(animationId) ~= "string" or animationId == "" then
		return nil
	end
	local markerName = AttackWindows.MarkerNameFor(moveId)
	if not markerName then
		return nil
	end
	local cached = markerCache[cacheKey(animationId, markerName)]
	if cached == nil or cached == false then
		return nil
	end
	return cached
end

export type ValidationRecord = {
	MoveId: string,
	AnimationId: string,
	MarkerName: string,
	HasMarker: boolean,
}

-- Warms the cache for every entry and reports what it found -- the same "missing becomes a startup
-- message, not a mid-fight mystery" shape ParryWindows.ValidateAll gives parry, at info rather than
-- warn: an M1 with no marker is not broken, it is exactly as correct as this game was before this
-- module existed. YIELDS -- call from Init, not a hot path.
function AttackWindows.ValidateAll(entries: { { MoveId: string, AnimationId: string } }): { ValidationRecord }
	local records: { ValidationRecord } = {}
	for _, entry in entries do
		local markerName = AttackWindows.MarkerNameFor(entry.MoveId)
		if not markerName or entry.AnimationId == "" then
			continue
		end
		local hasMarker = AttackWindows.Prefetch(entry.AnimationId, markerName)
		table.insert(records, {
			MoveId = entry.MoveId,
			AnimationId = entry.AnimationId,
			MarkerName = markerName,
			HasMarker = hasMarker,
		})
		if hasMarker then
			logger:info("M1 windup is marker-driven", { moveId = entry.MoveId, markerName = markerName })
		else
			logger:info("M1 windup is using the hardcoded Constants.lua value -- no usable marker found", {
				moveId = entry.MoveId,
				markerName = markerName,
			})
		end
	end
	return records
end

-- Testing ------------------------------------------------------------------------------------------

-- Swaps the extractor. Spec-only; the shipped code never calls it.
function AttackWindows.SetExtractor(nextExtractor: (animationId: string) -> KeyframeSequence?): ()
	extractor = nextExtractor
end

-- Drops every cache entry. Spec-only, so one case cannot serve another its markers.
function AttackWindows.Reset(): ()
	table.clear(markerCache)
	table.clear(inFlight)
end

return AttackWindows
