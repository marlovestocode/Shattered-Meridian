--!strict
--[[
	Animation/KeyframeMarkers.lua

	Owns: reading KeyframeMarkers off an authored KeyframeSequence -- the fetch, the walk over the
	Instance tree, and the retry budget that fetch is allowed to spend.

	WHY THE ASSET, NOT THE TRACK, is Shared/Defense/ParryWindows.lua's argument and it is stated in
	full there: playing the track to hear its markers makes the authority depend on animation
	replication, strands the read if the track is interrupted, and is untestable without a live
	Animator. This module is the mechanism that argument concluded with, extracted because a SECOND
	consumer (Shared/Attack/AttackWindows.lua, for marker-driven M1 windup) then wrote the same three
	pieces out again -- byte-identical fetch, a second walk over the same tree with the same
	earliest-wins rule, and its own copy of the same two retry numbers with a comment saying "identical
	budget to ParryWindows, for the identical reason."

	Does not own: what a marker MEANS. ParryWindows turns a marker map into an open/close window and
	refuses a half-authored pair; AttackWindows pulls one derived name and falls back to a hardcoded
	constant when it is absent. Those are opposite policies on the same data -- one fails closed, one
	fails soft -- and both stay with the module that has a reason for its choice. This module has no
	opinion about any particular marker name, and should not acquire one.

	Also does not own the CACHE. Both consumers memoize, and they key differently (ParryWindows by
	animation id, AttackWindows by the id-and-marker-name pair, because a marker name means nothing
	apart from the clip it came from). A shared cache would have to be keyed for the more specific of
	the two and would gain nothing but a shared table to invalidate wrongly.
]]

local KeyframeSequenceProvider = game:GetService("KeyframeSequenceProvider")

local KeyframeMarkers = {}

-- The retry budget a fetch is allowed to spend, shared because both consumers spend it against the
-- SAME rate-limited endpoint -- two independently tuned budgets would be two halves of one number.
-- Bounded because GetKeyframeSequenceAsync is rate limited: an id that is simply wrong would
-- otherwise be re-requested for the rest of the session, spending the budget the ids that DO resolve
-- need.
KeyframeMarkers.MaxAttempts = 3
KeyframeMarkers.RetryBaseSeconds = 0.5

-- Waits out the backoff before attempt N + 1. Linear in the attempt number, because the
-- overwhelmingly likely cause of a failed fetch is the rate limit and an immediate retry is the one
-- thing guaranteed to hit it again. YIELDS, obviously.
function KeyframeMarkers.Backoff(attempt: number): ()
	task.wait(KeyframeMarkers.RetryBaseSeconds * attempt)
end

-- One attempt at the authored sequence behind `animationId`, or nil if it could not be fetched.
-- YIELDS (a web call). Wrapped in a pcall rather than allowed to throw: a bad id, an unpublished
-- asset and a rate-limit rejection all arrive here as errors, and all three mean the same thing to
-- every caller -- no sequence this time.
--
-- Each consumer holds this as its own swappable `extractor` local rather than calling it directly, so
-- a spec can replace ONE module's fetch without reaching across into the other's. This is the default
-- they both start from, not a call site.
function KeyframeMarkers.Fetch(animationId: string): KeyframeSequence?
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

-- Every marker time on `sequence`, by marker name. Pure over the Instance tree it is handed -- no web
-- call, no cache, no yielding -- so a spec can build a KeyframeSequence with Instance.new and call
-- this directly, which is what both consumers' specs do.
--
-- A marker's time is its KEYFRAME's time; KeyframeMarker itself carries no time of its own. Duplicate
-- markers of the same name take the EARLIEST keyframe: an animator who left two copies on a clip
-- meant the first one, and picking the later one silently shifts whatever the marker drives.
--
-- Keyframe.Time is a FLOAT32, so a marker authored at 0.05 comes back as 0.05000000074505806. That is
-- far below any timing anyone can perceive and nothing here rounds it, but it does mean marker times
-- must never be compared for exact equality -- against an authored number, or against each other.
function KeyframeMarkers.TimesOn(sequence: KeyframeSequence): { [string]: number }
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

-- The marker names present on `sequence`, sorted, as one comma-separated string -- diagnostic only,
-- so a "no usable marker" log can say what WAS found instead of only what was not, and a typo or a
-- wrong-stage name shows up immediately instead of reading as "no markers at all".
function KeyframeMarkers.NamesOn(sequence: KeyframeSequence): string
	local names = {}
	for name in KeyframeMarkers.TimesOn(sequence) do
		table.insert(names, name)
	end
	table.sort(names)
	return if #names > 0 then table.concat(names, ", ") else "<none>"
end

return KeyframeMarkers
