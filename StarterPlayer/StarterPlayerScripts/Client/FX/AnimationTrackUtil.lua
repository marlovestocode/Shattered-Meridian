--!strict
--[[
	AnimationTrackUtil.lua

	Owns: two small pieces of pure AnimationTrack manipulation that Client/FX/CombatAnimator.lua
	and Client/FX/FlightAnimator.lua each used to hand-roll their own copy of:

	  1. DriveDominantLoop -- the per-Heartbeat "which of these mutually-exclusive looped tracks
		 should be playing THIS frame" evaluator. CombatAnimator's own Walking/Running crossfade and
		 FlightAnimator's Hover/CruiseLoop/BoostLoop pick are the exact same shape once each file's
		 own eligibility logic (moving/sprinting vs. flying/hovering/boosting) is stripped out --
		 mutually-exclusive tracks at Constants.FX.Animation.DominantWeight that need re-asserting
		 every Heartbeat, since Roblox's default Animate script keeps re-asserting its OWN track's
		 weight on every Humanoid movement-state change and a single Play()-time weight isn't
		 reliable against that (see DominantWeight's own header in Constants.lua). This function is
		 that evaluator, generic over however many entries a caller has -- callers compute their own
		 "should this be playing right now" booleans fresh every frame (they're the only ones who
		 know what moving/sprinting/flying/hovering/boosting mean); this owns only the resulting
		 Play/AdjustWeight/Stop mechanics.

	  2. FreezeGuard -- a generation-guarded "freeze these tracks' playback, resume after N seconds"
		 helper (the animation half of a hit-stop/landing-impact freeze-frame). Extracted because
		 CombatAnimator.FreezeActiveCombatTrack and FlightAnimator.FreezeActiveFlightTrack were NOT
		 quite the same, and this wasn't just a dedup: Combat's version froze every currently-playing
		 track and guarded the delayed restore with a generation counter, so an overlapping second
		 freeze couldn't let the first freeze's own timer resume playback early. Flight's version
		 only froze the FIRST track it found (a `break` after the first IsPlaying hit) and restored
		 unconditionally with no generation guard at all -- an overlapping freeze in flight mode
		 really could resume early or strand a second frozen track playing forever. FreezeGuard.New()
		 gives each caller its OWN independent generation counter (Combat's freezes and Flight's
		 freezes must never share one counter -- an unrelated flight freeze bumping past a pending
		 combat freeze's generation would wrongly suppress the combat restore, and vice versa), and
		 :FreezeTracks freezes every track handed to it, fixing Flight's first-track-only bug along
		 the way.

	Client-only (not Shared/) -- both callers are client-side presentation modules manipulating
	AnimationTracks loaded from the LOCAL player's own Animator; there is no server-side caller
	(BotAnimator.lua has no loop-evaluator or freeze behavior of its own to share this with) and no
	reason to expect one, unlike Shared/AnimatorUtil.lua's Instance-setup helper which BotAnimator.
	lua genuinely does need server-side too.

	Does not own: which tracks exist, what "should play" means for any specific track, or how long
	a freeze should last -- every caller supplies its own tracks, eligibility, and durations (e.g.
	each file's own Constants.FX.HitStop-derived duration stays exactly where it already reads it
	from).
]]

local AnimationTrackUtil = {}

export type DominantLoopEntry = {
	Track: AnimationTrack?,
	ShouldPlay: boolean,
	-- Fade used both to start/pick this track back up (Play()) and every subsequent per-Heartbeat
	-- AdjustWeight call while it keeps playing.
	PlayFadeSeconds: number,
	-- Fade used to Stop() this track when ShouldPlay flips false -- kept separate from
	-- PlayFadeSeconds since a caller may want a soft crossfade on one side and a fast interrupt-cut
	-- on the other (see CombatAnimator's own Walking<->Running toggle-vs-interrupt distinction).
	StopFadeSeconds: number,
}

-- Re-derives and applies "should this track be playing THIS frame" for every entry, called once
-- per Heartbeat by each caller's own connection. Each entry's ShouldPlay is a plain boolean the
-- caller already computed fresh this frame from its own live state -- this function owns only the
-- resulting mechanics: Play() a newly-eligible track, keep re-asserting `dominantWeight` on one
-- already playing, or Stop() one that just became ineligible.
function AnimationTrackUtil.DriveDominantLoop(entries: { DominantLoopEntry }, dominantWeight: number): ()
	for _, entry in entries do
		local track = entry.Track
		if not track then
			continue
		end
		if entry.ShouldPlay then
			if not track.IsPlaying then
				track:Play(entry.PlayFadeSeconds, dominantWeight)
			end
			track:AdjustWeight(dominantWeight)
		elseif track.IsPlaying then
			track:Stop(entry.StopFadeSeconds)
		end
	end
end

local FreezeGuard = {}
FreezeGuard.__index = FreezeGuard

export type FreezeGuardInstance = typeof(setmetatable(
	{} :: {
		generation: number,
	},
	FreezeGuard
))

-- One independent generation counter per instance -- construct a separate FreezeGuard per
-- logically-distinct track family (CombatAnimator's own combat tracks vs. FlightAnimator's own
-- flight tracks) so an unrelated freeze on one family can never affect the other's restore timing.
function AnimationTrackUtil.NewFreezeGuard(): FreezeGuardInstance
	return setmetatable({ generation = 0 }, FreezeGuard)
end

-- Momentarily freezes every currently-playing track in `tracks` (AdjustSpeed to 0, restored to
-- each track's own pre-freeze speed after `seconds`) -- the animation half of a hit-stop/
-- landing-impact freeze-frame; the caller owns duration selection and throttling, this only owns
-- the tracks. Purely local presentation: the frozen pose replicates to other clients for free, and
-- no server timing is touched.
--
-- Generation-guarded: a freeze started while an earlier freeze's own restore timer is still
-- pending bumps this instance's generation, so the earlier (now-stale) timer sees a mismatch and
-- skips its restore instead of resuming playback early or fighting the newer freeze for the same
-- tracks -- the newer freeze's own timer is the one that actually restores, once IT elapses. This
-- fixes what used to be a real bug in FlightAnimator.FreezeActiveFlightTrack (no generation guard
-- at all, so an overlapping freeze there really could resume early) and generalizes the guard
-- CombatAnimator.FreezeActiveCombatTrack already had to every caller.
function FreezeGuard.FreezeTracks(self: FreezeGuardInstance, tracks: { AnimationTrack }, seconds: number): ()
	local originalSpeeds: { [AnimationTrack]: number } = {}
	local frozenAny = false
	for _, track in tracks do
		if track.IsPlaying then
			originalSpeeds[track] = track.Speed
			track:AdjustSpeed(0)
			frozenAny = true
		end
	end
	if not frozenAny then
		return
	end

	self.generation += 1
	local generation = self.generation
	task.delay(seconds, function()
		-- A newer freeze superseded this one -- it owns the restore now, so this stale timer must
		-- not resume playback early.
		if self.generation ~= generation then
			return
		end
		for _, track in tracks do
			if track.IsPlaying then
				track:AdjustSpeed(originalSpeeds[track] or 1)
			end
		end
	end)
end

return AnimationTrackUtil
