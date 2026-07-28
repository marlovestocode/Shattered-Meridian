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

		 The generation guard alone was NOT sufficient, and the two holes it left are why animations
		 could go permanently dead mid-fight. Both are fixed here; both are worth stating explicitly
		 because both are silent (no error, no warning -- just a character that stops animating):

		   a) Overlapping freezes recorded the WRONG pre-freeze speed. The restore speed used to be
		      sampled per-call into a local, so a second freeze landing while the first was still
		      pending sampled tracks the first had ALREADY set to 0 and recorded 0 as their
		      "original." The restore then read `originalSpeeds[track] or 1` -- and 0 is truthy in
		      Lua, so the `or 1` fallback never fired -- restoring the tracks to speed 0, i.e.
		      freezing every combat animation forever. This was reachable constantly in real play:
		      Constants.FX.HitStop.MinIntervalSeconds throttles freezes to 0.1s apart, but
		      ParrySeconds (0.12), PostureBreakSeconds (0.14), VictimSeconds+HeavyBonusSeconds
		      (0.12) and FlightLandingHardSeconds (0.16) all EXCEED that throttle, so any parry,
		      posture break or heavy hit followed by a second impact within its own hold overlapped
		      by construction. The pre-freeze speed now lives on the guard instance and is recorded
		      once per freeze chain, so a nested freeze extends the hold instead of poisoning it.

		   b) The restore was gated on `track.IsPlaying`. AnimationTrack.Speed persists across
		      Stop()/Play(), so any track that was frozen and then stopped before the restore fired
		      (a hit-stop overlapping the locomotion evaluator crossfading Walking out, or a swing
		      clip completing under the freeze) kept Speed = 0 and played frozen the NEXT time it
		      started -- and every time after that, since nothing else ever writes Speed back. The
		      restore is now unconditional over exactly the set of tracks this guard actually froze.

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
		-- Every track this guard currently holds frozen, mapped to the speed it was playing at
		-- BEFORE the first freeze in the current (possibly overlapping) freeze chain took it to 0.
		-- Lives on the instance rather than as a per-FreezeTracks local because overlapping freezes
		-- must agree on one pre-freeze speed: the second freeze samples a track that the first
		-- already zeroed, so a per-call sample would record 0 as the "original" and restore it to 0
		-- forever. Cleared as a unit by whichever freeze's timer wins the generation check.
		frozenSpeeds: { [AnimationTrack]: number },
	},
	FreezeGuard
))

-- One independent generation counter per instance -- construct a separate FreezeGuard per
-- logically-distinct track family (CombatAnimator's own combat tracks vs. FlightAnimator's own
-- flight tracks) so an unrelated freeze on one family can never affect the other's restore timing.
function AnimationTrackUtil.NewFreezeGuard(): FreezeGuardInstance
	return setmetatable({ generation = 0, frozenSpeeds = {} }, FreezeGuard)
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
	local frozenSpeeds = self.frozenSpeeds
	local frozenAny = false
	for _, track in tracks do
		if frozenSpeeds[track] ~= nil then
			-- Already held frozen by an earlier freeze whose restore hasn't fired yet. Its real
			-- pre-freeze speed is already recorded, so DON'T re-sample (that would record the 0 this
			-- guard itself just set) -- just let this newer freeze take ownership of the restore
			-- below, which extends the hold rather than resuming mid-freeze.
			frozenAny = true
		elseif track.IsPlaying then
			frozenSpeeds[track] = track.Speed
			track:AdjustSpeed(0)
			frozenAny = true
		end
	end
	if not frozenAny then
		-- Nothing playing and nothing still held frozen: don't bump the generation, or an unrelated
		-- no-op freeze would orphan a pending restore and strand its tracks at speed 0.
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
		-- Restore every track this guard froze, NOT just the ones still playing, and not just the
		-- ones in the `tracks` list this particular call was handed. AnimationTrack.Speed persists
		-- across Stop()/Play(), so a track that was frozen and then stopped mid-freeze (a hit-stop
		-- landing while the locomotion evaluator crossfades Walking out, a swing completing under
		-- the freeze) would otherwise keep Speed = 0 and play frozen the NEXT time it's started --
		-- permanently, since nothing else ever writes Speed back.
		for track, speed in frozenSpeeds do
			track:AdjustSpeed(speed)
		end
		table.clear(frozenSpeeds)
	end)
end

return AnimationTrackUtil
