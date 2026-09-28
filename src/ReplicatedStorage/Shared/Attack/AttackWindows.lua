--!strict
--[[
	AttackWindows.lua

	Owns: what a swing clip's own authored asset says about its timing -- how long the clip really is,
	and the optional marker on its impact frame that says when it connects. Both are read
	off the clip's KeyframeSequence once per clip and cached; Server/Combat/AttackCatalog.Get is the
	one runtime caller, and the one place either number is turned into a swing's timeline.

	THE CLIP'S LENGTH IS THE SWING'S LENGTH (AttackConstants.Windows.SyncToClipLength). The client plays
	a swing clip at its own native length (AnimationManager expires a one-shot against track.Length,
	not against anything the server said), while the server used to run a hand-typed Windup+Active+
	Recovery timeline. Nothing ever checked one against the other, so every retuned number or re-cut
	clip silently desynchronised them: the attacker unlocked mid-animation, or stood committed after the
	clip had visibly finished. ClipLength below is what lets the server end the swing when the clip
	does. The length is the LAST keyframe's time, which is exactly what AnimationTrack.Length reports
	for the same asset -- so the server and the client are finally measuring the same thing.

	THE MARKER OVERRIDE IS FAIL-SOFT, UNLIKE Shared/Defense/ParryWindows.lua -- read that module's
	header first, since this one borrows its entire extraction mechanism (read the authored
	KeyframeSequence directly via KeyframeSequenceProvider, never play the track -- the same three
	reasons apply here verbatim: the server would have to play the track to hear it, an interrupted
	track would strand the read, and it would be untestable without a live Animator). The difference is
	what a MISSING marker means. Parry is an optional mechanic: no markers, no parry. An attack's hit
	timing is not optional -- every press must still deal damage on schedule even if an animator never
	touched a clip's markers, so absence here means "keep the hardcoded WindupSeconds," never
	"this move does not work." The same is true of a missing LENGTH: an unfetched or unreadable clip
	keeps the authored Windup+Active+Recovery exactly as before this module read lengths at all.

	TWO MARKER NAMES, ONE MEANING. Both mark the single instant the swing connects, which is exactly
	what WindupSeconds already means -- one marker per clip, not a pair.

	  - AttackConstants.Windows.HitMarkerName ("Hit") works on ANY attack clip: an M1, Heavy, Finisher,
	    a standalone, a Move Editor move or an Art. This is the one to author.
	  - "AttackM<stage>" is the older M1-only name, DERIVED FROM THE MOVE rather than looked up: a
	    Basic-string MoveId always has the shape "default:<WeaponId>:Basic:<stage>" (DefaultMoveRegistry's
	    own scheme, restated here the same way SwingSequencer/AttackCatalog already restate it), and its
	    clip's marker is AttackM1/AttackM2/AttackM3. Kept because clips already carry it; when an M1 clip
	    carries both names, the stage-specific one wins, since it is the more specific statement.

	A clip with neither keeps its move's authored WindupSeconds -- and still gets its LENGTH synced,
	since every clip has a length whether or not anyone marked it.

	ONE FETCH PER CLIP, NOT PER (clip, marker) PAIR. The length and every marker come off the same
	sequence, so the cache is keyed by animation id alone and holds everything that one fetch found.

	Does not own: turning these numbers into a timeline (AttackCatalog.Get -- the delay/active/recovery
	split, the Cooldown clamp, the weapon-speed scaling), or any playback (Client/Combat/
	AttackInputClient.lua plays whatever clip and speed the server's Attack_Started names).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AttackConstants = require(ReplicatedStorage.Shared.Attack.AttackConstants)
local KeyframeMarkers = require(ReplicatedStorage.Shared.Animation.KeyframeMarkers)
local Logger = require(ReplicatedStorage.Shared.Logger)

local logger = Logger.scope("AttackWindows")

local AttackWindows = {}

-- Everything one clip's authored sequence said about its timing.
type ClipTiming = {
	-- nil when the sequence carried no keyframe past zero -- a clip with nothing to sync to.
	Length: number?,
	-- Only the usable ones (see isUsableTime), so a reader never has to re-check a time it is handed.
	Markers: { [string]: number },
}

-- Successfully read clips, keyed by animation id. Also holds `false` for a clip whose extraction
-- failed its last attempt -- the negative cache, distinguished from "never asked" (nil) the same way
-- ParryWindows.markerCache is, and for the same reason: a permanent failure is never retried, a fresh
-- id still can be.
local clipCache: { [string]: ClipTiming | false } = {}
-- Ids with an extraction in flight, so concurrent Prefetch calls for the same clip await the one
-- request rather than each starting their own.
local inFlight: { [string]: boolean } = {}

-- Swappable so specs can drive extraction without a published asset -- same seam, same contract as
-- ParryWindows.extractor, and the same shared default behind both. Held as a local rather than called
-- through the module so a spec can replace THIS module's fetch without reaching into ParryWindows'.
-- Never called on a non-yielding read path -- see WindupOverride/ClipLength.
local extractor: (animationId: string) -> KeyframeSequence? = KeyframeMarkers.Fetch

-- NaN-safe and non-negative -- a time before the clip's own start describes nothing, the same floor
-- ParryWindows.isSane holds its own Open time to.
local function isUsableTime(value: number): boolean
	return value == value and value >= 0
end

-- One marker's time off an authored sequence, or nil. Kept as a named function on this module because
-- it is the seam AttackWindows.spec asserts the earliest-wins rule through -- the rule itself, and the
-- float32 caveat that comes with it, live in Animation/KeyframeMarkers.TimesOn.
function AttackWindows.ExtractMarkerTime(sequence: KeyframeSequence, markerName: string): number?
	return KeyframeMarkers.TimesOn(sequence)[markerName]
end

-- The clip's length: its LAST keyframe's time, which is what AnimationTrack.Length reports for the
-- same asset on the client. nil for a sequence with no keyframe past zero -- a zero-length clip is
-- nothing to sync a swing to, and syncing to it would collapse the whole swing into its hit frame.
function AttackWindows.ExtractClipLength(sequence: KeyframeSequence): number?
	local length = 0
	for _, child in sequence:GetChildren() do
		if child:IsA("Keyframe") then
			local keyframeTime = child.Time
			if isUsableTime(keyframeTime) and keyframeTime > length then
				length = keyframeTime
			end
		end
	end
	return if length > 0 then length else nil
end

-- The M1 stage-specific marker name for `moveId` ("AttackM<stage>"), or nil if it is not shaped like
-- a Basic stage -- see this file's header for the scheme. Every other move is timed by the generic
-- Hit marker alone (see resolveMarker below).
function AttackWindows.MarkerNameFor(moveId: string): string?
	local stage = string.match(moveId, "^default:%a+:Basic:(%d+)$")
	if not stage then
		return nil
	end
	return "AttackM" .. stage
end

local function readSequence(sequence: KeyframeSequence): ClipTiming
	local markers: { [string]: number } = {}
	for name, markerTime in KeyframeMarkers.TimesOn(sequence) do
		if isUsableTime(markerTime) then
			markers[name] = markerTime
		end
	end
	return { Length = AttackWindows.ExtractClipLength(sequence), Markers = markers }
end

-- Fetches and caches one clip's timing. YIELDS (GetKeyframeSequenceAsync is a web call). Safe to call
-- concurrently for the same clip -- the second caller waits on the first one's request rather than
-- starting another, the identical shape ParryWindows.Prefetch uses.
--
-- Returns true if the clip's sequence was read, whether or not it carried a marker or a usable
-- length. A false return is not necessarily a problem -- see this file's header on why absence here
-- means "authored timing," not "broken."
function AttackWindows.Prefetch(animationId: string): boolean
	if typeof(animationId) ~= "string" or animationId == "" then
		return false
	end
	local cached = clipCache[animationId]
	if cached ~= nil then
		return cached ~= false
	end

	if inFlight[animationId] then
		while inFlight[animationId] do
			task.wait()
		end
		local settled = clipCache[animationId]
		return settled ~= nil and settled ~= false
	end

	inFlight[animationId] = true
	local resolved: ClipTiming | false = false
	for attempt = 1, KeyframeMarkers.MaxAttempts do
		local sequence = extractor(animationId)
		if sequence then
			resolved = readSequence(sequence)
			break
		end
		if attempt < KeyframeMarkers.MaxAttempts then
			KeyframeMarkers.Backoff(attempt)
		end
	end

	-- Written before clearing the in-flight flag, so a waiter that wakes on the flag always sees the
	-- settled value rather than racing the write.
	clipCache[animationId] = resolved
	inFlight[animationId] = nil
	return resolved ~= false
end

-- Starts a background Prefetch for a clip nobody has asked about yet, and returns immediately. NEVER
-- YIELDS. For the throw path: a clip that first appears mid-session (a custom move authored in the
-- Move Editor, a weapon override the boot pass could not see) swings on its authored timing once and
-- is synced from the next swing on, instead of waiting for a server restart.
function AttackWindows.Request(animationId: string): ()
	if typeof(animationId) ~= "string" or animationId == "" then
		return
	end
	if clipCache[animationId] ~= nil or inFlight[animationId] then
		return
	end
	task.spawn(AttackWindows.Prefetch, animationId)
end

local function cachedTiming(animationId: string): ClipTiming?
	if typeof(animationId) ~= "string" or animationId == "" then
		return nil
	end
	local cached = clipCache[animationId]
	if cached == nil or cached == false then
		return nil
	end
	return cached
end

-- Which marker on `timing` times `moveId`'s hitbox, and when: the M1 stage-specific name first, the
-- generic Hit marker second, or (nil, nil) when the clip carries neither. See this file's header for
-- why that order.
local function resolveMarker(moveId: string, timing: ClipTiming): (string?, number?)
	local stageMarker = AttackWindows.MarkerNameFor(moveId)
	if stageMarker then
		local stageTime = timing.Markers[stageMarker]
		if stageTime then
			return stageMarker, stageTime
		end
	end
	local hitMarker = AttackConstants.Windows.HitMarkerName
	local hitTime = timing.Markers[hitMarker]
	if hitTime then
		return hitMarker, hitTime
	end
	return nil, nil
end

-- The cached WindupSeconds override for `moveId`/`animationId`, in CLIP time (seconds at playback
-- speed 1 -- AttackCatalog scales it by the weapon's speed), or nil. NEVER YIELDS, same contract as
-- ParryWindows.Get. Returns nil unconditionally while AttackConstants.Windows.Enabled is false, for a
-- blank animationId, or for a clip that was never prefetched (or carries no usable Hit/AttackM<n>
-- marker for this move) -- every one of those means "the caller keeps whatever hardcoded value it
-- already had," never an error.
function AttackWindows.WindupOverride(moveId: string, animationId: string): number?
	if not AttackConstants.Windows.Enabled then
		return nil
	end
	local timing = cachedTiming(animationId)
	if not timing then
		return nil
	end
	local _, markerTime = resolveMarker(moveId, timing)
	return markerTime
end

-- The cached length of `animationId`'s clip in CLIP time (seconds at playback speed 1), or nil. NEVER
-- YIELDS. nil while AttackConstants.Windows.SyncToClipLength is false, for a blank id, or for a clip
-- that has not been read (or had no keyframes) -- all of which mean "keep the authored timeline."
function AttackWindows.ClipLength(animationId: string): number?
	if not AttackConstants.Windows.SyncToClipLength then
		return nil
	end
	local timing = cachedTiming(animationId)
	return if timing then timing.Length else nil
end

-- The marker names a clip carried, sorted and joined -- diagnostic only, so a "no usable marker" log
-- says what WAS found and a typo or a wrong-stage name shows up immediately.
local function markerNamesOf(timing: ClipTiming): string
	local names = {}
	for name in timing.Markers do
		table.insert(names, name)
	end
	table.sort(names)
	return if #names > 0 then table.concat(names, ", ") else "<none>"
end

export type ValidationRecord = {
	MoveId: string,
	AnimationId: string,
	-- Whether the clip's sequence could be read at all.
	Read: boolean,
	-- nil when the clip had nothing to sync to, or could not be read.
	ClipLength: number?,
	-- The marker that times this move's hitbox (Hit or AttackM<n>), or nil when the clip carries
	-- neither and the move keeps its authored WindupSeconds.
	MarkerName: string?,
	HasMarker: boolean,
}

-- Warms the cache for every entry with a clip and reports what it found -- the same "missing becomes a
-- startup message, not a mid-fight mystery" shape ParryWindows.ValidateAll gives parry. A clip that
-- cannot be read is a warn (that move swings on a hand-typed timeline that may not match what players
-- see); a clip with no marker is only info (its hardcoded windup is exactly as correct as it was
-- before markers existed), but the line says so, so "which moves still need a Hit marker" is one read
-- of the boot log. Entries sharing a clip cost one fetch between them. YIELDS -- call from Init, not a
-- hot path.
function AttackWindows.ValidateAll(entries: { { MoveId: string, AnimationId: string } }): { ValidationRecord }
	local records: { ValidationRecord } = {}
	for _, entry in entries do
		if entry.AnimationId == "" then
			continue
		end
		local wasRead = AttackWindows.Prefetch(entry.AnimationId)
		local timing = cachedTiming(entry.AnimationId)
		local markerName, markerTime = nil, nil
		if timing then
			markerName, markerTime = resolveMarker(entry.MoveId, timing)
		end
		local record: ValidationRecord = {
			MoveId = entry.MoveId,
			AnimationId = entry.AnimationId,
			Read = wasRead,
			ClipLength = if timing then timing.Length else nil,
			MarkerName = markerName,
			HasMarker = markerName ~= nil,
		}
		table.insert(records, record)

		if not timing then
			logger:warn("Swing clip could not be read -- this move keeps its hand-typed timeline", {
				moveId = entry.MoveId,
				animationId = entry.AnimationId,
			})
			continue
		end
		if markerName then
			logger:info("Swing clip read -- hitbox timed by marker", {
				moveId = entry.MoveId,
				clipSeconds = record.ClipLength,
				marker = markerName,
				markerSeconds = markerTime,
			})
		else
			logger:info("Swing clip read -- no Hit marker, hitbox timed by WindupSeconds", {
				moveId = entry.MoveId,
				clipSeconds = record.ClipLength,
				expected = AttackConstants.Windows.HitMarkerName,
				foundMarkers = markerNamesOf(timing),
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

-- Drops every cache entry. Spec-only, so one case cannot serve another its clips.
function AttackWindows.Reset(): ()
	table.clear(clipCache)
	table.clear(inFlight)
end

return AttackWindows
