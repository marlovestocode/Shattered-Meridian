--!strict
--[[
	AnimationTimeline.lua

	Owns: the authored multi-clip animation model for a Move Creation System move, and the ONE pure
	function (Resolve) that turns an author's clip list into a concrete, ordered playback schedule.

	Before this module a move had exactly one AnimationId that started at t=0 and was never
	explicitly stopped. That is now the degenerate case of a general model: a move carries an ORDERED
	list of clips, each of which independently answers

	  * when do I start   -- at a fixed time, at the start of a named phase, or right after the
	                         previous clip finishes, plus an optional extra delay;
	  * when do I stop    -- after a fixed duration, at the end of the phase I started in, at the end
	                         of the whole move, or never (let the clip play itself out);
	  * how do I play     -- speed, weight, fade in/out, looping;
	  * how do I interact -- Overlap (ignore everything else), Exclusive (cut short whatever is still
	                         running when I start), or Queue (never start before the previous clip
	                         has finished, even if my own start time says otherwise);
	  * what happens if the move is interrupted -- Stop, Freeze on the current pose, or PlayThrough.

	Resolve is deliberately PURE and total: same clips + same phase timings in, same schedule out, no
	Instance access, no yielding, no clock reads. That is what lets the exact same resolved schedule
	drive three different consumers that must never disagree -- the live client-side player
	(CombatAnimator), the editor's own preview playback (PreviewViewport), and the editor's timeline
	drawing and stats (MoveStats/StatsPanel). A preview that plays a different sequence than the real
	move is the specific failure this shape exists to make structurally impossible.

	Interrupt behaviour (Clip.OnInterrupt) is deliberately NOT resolved here -- it isn't a function of
	the timeline, it's a function of an event that may never happen. Resolve carries it through onto
	each ScheduledClip unchanged and the runtime consults it if and when an interrupt actually
	arrives.

	Does not own: loading or playing an AnimationTrack (CombatAnimator on the client, the preview's
	own Animator in the editor), validation against DataStore/network input (MoveRegistryManager
	.Validate calls Sanitize below and treats its result as authoritative), or the move's phase
	durations themselves (MoveDefinition's own WindupSeconds/ActiveSeconds/RecoverySeconds).
]]

local AnimationTimeline = {}

export type MovePhase = "Windup" | "Active" | "Recovery"

-- When a clip begins. "AfterPrevious" is resolved against the previous ENABLED clip in play order,
-- so disabling a clip mid-chain closes the gap rather than leaving a hole.
export type ClipStartMode = "Time" | "Phase" | "AfterPrevious"

-- When a clip ends. "Natural" means this module never schedules a stop at all -- the clip plays for
-- its own authored length and finishes on its own (the pre-timeline behaviour, and still the right
-- answer for a one-shot swing clip whose length already matches the move). Every other mode
-- produces an explicit stop time.
export type ClipStopMode = "Duration" | "PhaseEnd" | "MoveEnd" | "Natural"

-- How a clip treats clips already running when it starts.
export type ClipBlend = "Overlap" | "Exclusive" | "Queue"

-- What happens to a still-playing clip when the move itself is cut short (a feint, a stun, the
-- attacker dying). Carried through Resolve untouched -- see this file's header.
export type ClipInterrupt = "Stop" | "Freeze" | "PlayThrough"

export type Clip = {
	-- Stable within one move, assigned once at creation (NextClipId below) and never reused --
	-- the editor's per-row UI state and Resolve's own ordering both key off it, so reordering or
	-- deleting a sibling must not renumber it.
	ClipId: string,
	-- Author-facing label ("Wind up", "Slash", "Recover") -- display only, never matched on.
	Name: string,
	AnimationId: string,
	Enabled: boolean,
	-- Explicit play order, independent of the clip's position in the array -- the editor's
	-- move-up/move-down buttons rewrite this rather than reshuffling the array, so a clip's
	-- identity/ClipId stays put. Ties break on array position, making Resolve stable.
	Order: number,

	StartMode: ClipStartMode,
	StartTime: number,
	StartPhase: MovePhase,
	-- Added on top of whichever start the mode resolved to -- lets an author say "at the start of
	-- Active, plus 0.05s" without abandoning phase-relative timing for a raw number that would stop
	-- tracking the phase if they later retune it.
	StartDelay: number,

	StopMode: ClipStopMode,
	DurationSeconds: number,

	Speed: number,
	Weight: number,
	FadeInSeconds: number,
	FadeOutSeconds: number,
	Looped: boolean,

	Blend: ClipBlend,
	OnInterrupt: ClipInterrupt,
}

export type PhaseTimings = {
	WindupSeconds: number,
	ActiveSeconds: number,
	RecoverySeconds: number,
}

export type ScheduledClip = {
	Clip: Clip,
	-- 1-based position in the RESOLVED play order (not the authored array index).
	Index: number,
	StartSeconds: number,
	-- Always finite, always >= StartSeconds. For StopMode == "Natural" this is the move's own end,
	-- used purely for drawing/statistics; LetPlayOut below is what tells a runtime not to actually
	-- call Stop at that moment.
	StopSeconds: number,
	DurationSeconds: number,
	-- True only for StopMode == "Natural" AND only while no later Exclusive clip cut it short --
	-- the runtime skips its scheduled Stop entirely in that case and lets the track finish itself.
	LetPlayOut: boolean,
	-- Which rule actually decided StopSeconds. "Exclusive" means a later clip cut this one short,
	-- overriding whatever its own StopMode asked for -- surfaced so the editor can show the author
	-- that one of their clips is being truncated by another rather than leaving them to work it out
	-- from two numbers that don't match.
	StoppedBy: "Duration" | "PhaseEnd" | "MoveEnd" | "Natural" | "Exclusive",
	-- True when Blend == "Queue" pushed this clip's start later than its own StartMode asked for.
	-- Same reasoning as StoppedBy: the editor shows it, nothing branches on it.
	DelayedByQueue: boolean,
}

--
-- Authoring bounds -- the single source of truth for both MoveRegistryManager's clamps and the
-- editor's own NumericField Min/Max, exactly as HitboxShapes.FIELD_SPECS is for dimensions.
--

AnimationTimeline.Limits = {
	MaxClips = 8,
	MinStartTime = 0,
	MaxStartTime = 10,
	MinStartDelay = 0,
	MaxStartDelay = 5,
	MinDuration = 0.02,
	MaxDuration = 10,
	MinSpeed = 0.05,
	MaxSpeed = 5,
	MinWeight = 0.05,
	MaxWeight = 10,
	MinFade = 0,
	MaxFade = 2,
	MinOrder = 1,
	MaxOrder = 64,
	MaxNameLength = 40,
	MaxAnimationIdLength = 120,
}

local Limits = AnimationTimeline.Limits

local START_MODES: { [string]: boolean } = { Time = true, Phase = true, AfterPrevious = true }
local STOP_MODES: { [string]: boolean } = { Duration = true, PhaseEnd = true, MoveEnd = true, Natural = true }
local BLEND_MODES: { [string]: boolean } = { Overlap = true, Exclusive = true, Queue = true }
local INTERRUPT_MODES: { [string]: boolean } = { Stop = true, Freeze = true, PlayThrough = true }
local PHASES: { [string]: boolean } = { Windup = true, Active = true, Recovery = true }

-- Ordered for the editor's own dropdowns -- declaration order is presentation order.
AnimationTimeline.StartModeOrder = { "Time", "Phase", "AfterPrevious" } :: { ClipStartMode }
AnimationTimeline.StopModeOrder = { "Duration", "PhaseEnd", "MoveEnd", "Natural" } :: { ClipStopMode }
AnimationTimeline.BlendOrder = { "Overlap", "Exclusive", "Queue" } :: { ClipBlend }
AnimationTimeline.InterruptOrder = { "Stop", "Freeze", "PlayThrough" } :: { ClipInterrupt }
AnimationTimeline.PhaseOrder = { "Windup", "Active", "Recovery" } :: { MovePhase }

--
-- Phase helpers
--

function AnimationTimeline.TotalDuration(timings: PhaseTimings): number
	return timings.WindupSeconds + timings.ActiveSeconds + timings.RecoverySeconds
end

-- Seconds from the move's start at which `phase` begins.
function AnimationTimeline.PhaseStart(timings: PhaseTimings, phase: MovePhase): number
	if phase == "Windup" then
		return 0
	elseif phase == "Active" then
		return timings.WindupSeconds
	end
	return timings.WindupSeconds + timings.ActiveSeconds
end

function AnimationTimeline.PhaseEnd(timings: PhaseTimings, phase: MovePhase): number
	if phase == "Windup" then
		return timings.WindupSeconds
	elseif phase == "Active" then
		return timings.WindupSeconds + timings.ActiveSeconds
	end
	return AnimationTimeline.TotalDuration(timings)
end

-- Which phase a given elapsed time falls in. Anything at or past the move's end reports "Recovery"
-- (the last phase) rather than erroring -- callers are drawing a scrubber or tinting a gizmo, and a
-- time exactly at the boundary is a routine floating-point occurrence, not an error condition.
function AnimationTimeline.PhaseAt(timings: PhaseTimings, elapsed: number): MovePhase
	if elapsed < timings.WindupSeconds then
		return "Windup"
	elseif elapsed < timings.WindupSeconds + timings.ActiveSeconds then
		return "Active"
	end
	return "Recovery"
end

--
-- Authoring
--

-- Unique-within-a-move clip id. Never reused, never renumbered -- see Clip.ClipId's own header.
-- Derived from the highest existing numeric suffix rather than the clip COUNT, so deleting the
-- middle of a list can't produce a collision with a survivor.
function AnimationTimeline.NextClipId(existing: { Clip }): string
	local highest = 0
	for _, clip in ipairs(existing) do
		local suffix = tonumber(clip.ClipId:match("^clip(%d+)$") or "")
		if suffix and suffix > highest then
			highest = suffix
		end
	end
	return "clip" .. tostring(highest + 1)
end

-- A sensible new clip: plays from the start of the move at native speed and full weight, stops on
-- its own. Deliberately identical in effect to the single-AnimationId behaviour that predates this
-- module, so adding the first clip to a move changes nothing until the author changes something.
function AnimationTimeline.DefaultClip(clipId: string, order: number, animationId: string?): Clip
	return {
		ClipId = clipId,
		Name = "Clip " .. tostring(order),
		AnimationId = animationId or "",
		Enabled = true,
		Order = math.clamp(order, Limits.MinOrder, Limits.MaxOrder),
		StartMode = "Time",
		StartTime = 0,
		StartPhase = "Windup",
		StartDelay = 0,
		StopMode = "Natural",
		DurationSeconds = 0.5,
		Speed = 1,
		Weight = 1,
		FadeInSeconds = 0.1,
		FadeOutSeconds = 0.1,
		Looped = false,
		Blend = "Overlap",
		OnInterrupt = "Stop",
	}
end

-- The one clip list a move authored BEFORE this module existed resolves to: its single AnimationId,
-- starting at t=0, playing itself out. Called by MoveRegistryManager.Validate whenever a candidate
-- carries an AnimationId but no Animations array, which is exactly every record persisted under the
-- previous schema version -- so an old move keeps behaving identically without any migration pass.
function AnimationTimeline.FromLegacyAnimationId(animationId: string): { Clip }
	if animationId == "" then
		return {}
	end
	local clip = AnimationTimeline.DefaultClip("clip1", 1, animationId)
	clip.Name = "Main"
	return { clip }
end

local function clampNumber(value: unknown, min: number, max: number, fallback: number): number
	if typeof(value) ~= "number" then
		return fallback
	end
	local number = value :: number
	if number ~= number then
		-- NaN survives math.clamp -- reject it here rather than let it poison every downstream
		-- comparison in Resolve.
		return fallback
	end
	return math.clamp(number, min, max)
end

local function readEnum(value: unknown, allowed: { [string]: boolean }, fallback: string): string
	if typeof(value) == "string" and allowed[value :: string] then
		return value :: string
	end
	return fallback
end

local function readString(value: unknown, maxLength: number, fallback: string): string
	if typeof(value) ~= "string" then
		return fallback
	end
	local text = value :: string
	if #text > maxLength then
		return text:sub(1, maxLength)
	end
	return text
end

-- Normalizes one arbitrary (client-submitted, DataStore-decoded, or hand-written) table into a
-- legal Clip. Never rejects: every field falls back to the corresponding DefaultClip value, the
-- same "an in-range numeric error is clamped, not refused" philosophy MoveRegistryManager's own
-- header documents for the rest of the move. The one thing a caller must still check is the clip
-- COUNT (Limits.MaxClips) -- Sanitize below does that.
function AnimationTimeline.SanitizeClip(raw: unknown, clipId: string, order: number): Clip
	local fallback = AnimationTimeline.DefaultClip(clipId, order)
	if typeof(raw) ~= "table" then
		return fallback
	end
	local source = raw :: { [string]: unknown }

	return {
		ClipId = clipId,
		Name = readString(source.Name, Limits.MaxNameLength, fallback.Name),
		AnimationId = readString(source.AnimationId, Limits.MaxAnimationIdLength, ""),
		Enabled = if typeof(source.Enabled) == "boolean" then source.Enabled :: boolean else true,
		Order = math.floor(clampNumber(source.Order, Limits.MinOrder, Limits.MaxOrder, order)),
		StartMode = readEnum(source.StartMode, START_MODES, fallback.StartMode) :: ClipStartMode,
		StartTime = clampNumber(source.StartTime, Limits.MinStartTime, Limits.MaxStartTime, fallback.StartTime),
		StartPhase = readEnum(source.StartPhase, PHASES, fallback.StartPhase) :: MovePhase,
		StartDelay = clampNumber(source.StartDelay, Limits.MinStartDelay, Limits.MaxStartDelay, fallback.StartDelay),
		StopMode = readEnum(source.StopMode, STOP_MODES, fallback.StopMode) :: ClipStopMode,
		DurationSeconds = clampNumber(
			source.DurationSeconds,
			Limits.MinDuration,
			Limits.MaxDuration,
			fallback.DurationSeconds
		),
		Speed = clampNumber(source.Speed, Limits.MinSpeed, Limits.MaxSpeed, fallback.Speed),
		Weight = clampNumber(source.Weight, Limits.MinWeight, Limits.MaxWeight, fallback.Weight),
		FadeInSeconds = clampNumber(source.FadeInSeconds, Limits.MinFade, Limits.MaxFade, fallback.FadeInSeconds),
		FadeOutSeconds = clampNumber(source.FadeOutSeconds, Limits.MinFade, Limits.MaxFade, fallback.FadeOutSeconds),
		Looped = if typeof(source.Looped) == "boolean" then source.Looped :: boolean else false,
		Blend = readEnum(source.Blend, BLEND_MODES, fallback.Blend) :: ClipBlend,
		OnInterrupt = readEnum(source.OnInterrupt, INTERRUPT_MODES, fallback.OnInterrupt) :: ClipInterrupt,
	}
end

-- Normalizes a whole clip array: caps the count at Limits.MaxClips (extra clips are dropped, not
-- rejected -- see SanitizeClip), and re-derives every ClipId positionally so a client can never
-- submit two clips sharing one id and confuse the editor's own per-row state. ClipId stability
-- across a normal edit is preserved by the client sending the array in the same order it holds it.
function AnimationTimeline.Sanitize(raw: unknown): { Clip }
	if typeof(raw) ~= "table" then
		return {}
	end
	local source = raw :: { unknown }
	local clips: { Clip } = {}
	for index, entry in ipairs(source) do
		if index > Limits.MaxClips then
			break
		end
		table.insert(clips, AnimationTimeline.SanitizeClip(entry, "clip" .. tostring(index), index))
	end
	return clips
end

--
-- Resolution
--

-- Turns an authored clip list plus the move's own phase durations into the concrete play schedule.
-- See this file's header for why this is pure. Disabled clips and clips with no AnimationId are
-- dropped up front -- an empty AnimationId is the established "wired but not authored yet"
-- convention (Constants.Combat.AnimationIds), not something to schedule and fail to load.
function AnimationTimeline.Resolve(clips: { Clip }, timings: PhaseTimings): { ScheduledClip }
	local total = AnimationTimeline.TotalDuration(timings)

	-- Stable sort by Order: ipairs position is captured first and used as the tiebreak, so two
	-- clips sharing an Order keep their authored relative order instead of flipping arbitrarily
	-- between calls (which would make the preview non-deterministic).
	local playable: { { clip: Clip, position: number } } = {}
	for position, clip in ipairs(clips) do
		if clip.Enabled and clip.AnimationId ~= "" then
			table.insert(playable, { clip = clip, position = position })
		end
	end
	table.sort(playable, function(a, b)
		if a.clip.Order ~= b.clip.Order then
			return a.clip.Order < b.clip.Order
		end
		return a.position < b.position
	end)

	local scheduled: { ScheduledClip } = {}
	local previousStop = 0

	for index, entry in ipairs(playable) do
		local clip = entry.clip

		local start: number
		if clip.StartMode == "Phase" then
			start = AnimationTimeline.PhaseStart(timings, clip.StartPhase)
		elseif clip.StartMode == "AfterPrevious" then
			start = previousStop
		else
			start = clip.StartTime
		end
		start += clip.StartDelay

		-- Queue is a hard ordering constraint, applied AFTER the mode resolved its own start: the
		-- clip may start later than it asked to, never earlier. Overlap/Exclusive both let a clip
		-- start whenever its own timing says.
		local delayedByQueue = false
		if clip.Blend == "Queue" and start < previousStop then
			start = previousStop
			delayedByQueue = true
		end

		start = math.clamp(start, 0, total)

		local stop: number
		local stoppedBy: "Duration" | "PhaseEnd" | "MoveEnd" | "Natural" | "Exclusive"
		if clip.StopMode == "Duration" then
			stop = start + clip.DurationSeconds
			stoppedBy = "Duration"
		elseif clip.StopMode == "PhaseEnd" then
			-- The phase the clip actually STARTS in, not its authored StartPhase -- a clip whose
			-- StartDelay pushed it into the next phase should end with the phase it's really
			-- playing over, which is what an author watching the preview would expect.
			stop = AnimationTimeline.PhaseEnd(timings, AnimationTimeline.PhaseAt(timings, start))
			stoppedBy = "PhaseEnd"
		elseif clip.StopMode == "MoveEnd" then
			stop = total
			stoppedBy = "MoveEnd"
		else
			stop = total
			stoppedBy = "Natural"
		end
		stop = math.max(stop, start)

		table.insert(scheduled, {
			Clip = clip,
			Index = index,
			StartSeconds = start,
			StopSeconds = stop,
			DurationSeconds = stop - start,
			LetPlayOut = clip.StopMode == "Natural",
			StoppedBy = stoppedBy,
			DelayedByQueue = delayedByQueue,
		})

		previousStop = stop
	end

	-- Exclusive pass, applied only after every clip has a provisional window: an Exclusive clip
	-- truncates every EARLIER-ordered clip still running at the moment it starts. Done as a second
	-- pass rather than inline because an Exclusive clip's own start can itself be pushed later by
	-- Queue above, and truncating against a start that hasn't settled yet would cut the wrong
	-- clips.
	for laterIndex, later in ipairs(scheduled) do
		if later.Clip.Blend ~= "Exclusive" then
			continue
		end
		for earlierIndex = 1, laterIndex - 1 do
			local earlier = scheduled[earlierIndex]
			if earlier.StopSeconds > later.StartSeconds and earlier.StartSeconds <= later.StartSeconds then
				earlier.StopSeconds = later.StartSeconds
				earlier.DurationSeconds = math.max(earlier.StopSeconds - earlier.StartSeconds, 0)
				earlier.LetPlayOut = false
				earlier.StoppedBy = "Exclusive"
			end
		end
	end

	return scheduled
end

-- Which scheduled clips are live at `elapsed` -- the preview's per-frame query, and the basis for
-- the timeline strip's own "what's playing right now" highlight. Inclusive at the start, exclusive
-- at the stop, so two back-to-back clips never both report live on the boundary frame.
function AnimationTimeline.ActiveAt(scheduled: { ScheduledClip }, elapsed: number): { ScheduledClip }
	local live: { ScheduledClip } = {}
	for _, entry in ipairs(scheduled) do
		if elapsed >= entry.StartSeconds and elapsed < entry.StopSeconds then
			table.insert(live, entry)
		end
	end
	return live
end

-- The last moment any clip is still playing -- may exceed the move's own duration only in the
-- degenerate case of an empty schedule (0). Used by the editor to warn when a clip's window has
-- been squeezed to nothing by the move's timing.
function AnimationTimeline.ScheduleEnd(scheduled: { ScheduledClip }): number
	local latest = 0
	for _, entry in ipairs(scheduled) do
		if entry.StopSeconds > latest then
			latest = entry.StopSeconds
		end
	end
	return latest
end

return AnimationTimeline
