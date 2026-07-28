--!strict
local StarterPlayer = game:GetService("StarterPlayer")

local AnimationTrackUtil = require(StarterPlayer.StarterPlayerScripts.Client.FX.AnimationTrackUtil)

-- Regression coverage for FreezeGuard's restore path -- the two defects here were both silent
-- (no error, no warning, just a character that stops animating and never recovers until it
-- respawns), which is exactly the class of bug that needs a test rather than a code comment:
--
--   a) an overlapping freeze sampling the pre-freeze speed off tracks a PREVIOUS freeze had
--      already zeroed, then restoring to that 0 (the `originalSpeeds[track] or 1` fallback never
--      fired, because 0 is truthy in Lua), and
--   b) the restore skipping any track that had stopped during the freeze window -- Speed persists
--      across Stop()/Play(), so those tracks stayed at 0 for every subsequent play.
--
-- FreezeGuard only ever touches .IsPlaying/.Speed/:AdjustSpeed on the tracks it's handed, so a
-- plain table stands in for an AnimationTrack -- no real Animator/rig/asset needed, which keeps
-- these assertions deterministic instead of depending on a loaded animation asset. The `:: any`
-- cast is what lets the fake satisfy the `{ AnimationTrack }` parameter under --!strict.

type FakeTrack = {
	IsPlaying: boolean,
	Speed: number,
	AdjustSpeed: (self: any, speed: number) -> (),
}

local function newFakeTrack(speed: number?): FakeTrack
	return {
		IsPlaying = true,
		Speed = speed or 1,
		AdjustSpeed = function(self: any, newSpeed: number): ()
			self.Speed = newSpeed
		end,
	}
end

local function freeze(guard: any, tracks: { FakeTrack }, seconds: number): ()
	guard:FreezeTracks(tracks :: any, seconds)
end

-- Freeze durations are kept short so the suite stays fast, and every wait clears the longest
-- pending restore by a wide margin -- these assert ordering/bookkeeping, never precise timing.
local FREEZE_SECONDS = 0.08
local SETTLE_SECONDS = 0.4

return function()
	describe("FreezeGuard.FreezeTracks", function()
		it("zeroes the speed of every playing track it is handed", function()
			local guard = AnimationTrackUtil.NewFreezeGuard()
			local first = newFakeTrack()
			local second = newFakeTrack()

			freeze(guard, { first, second }, FREEZE_SECONDS)

			expect(first.Speed).to.equal(0)
			expect(second.Speed).to.equal(0)
		end)

		it("leaves a track that was not playing untouched", function()
			local guard = AnimationTrackUtil.NewFreezeGuard()
			local idle = newFakeTrack()
			idle.IsPlaying = false

			freeze(guard, { idle }, FREEZE_SECONDS)

			expect(idle.Speed).to.equal(1)
		end)

		it("restores the pre-freeze speed once the hold elapses", function()
			local guard = AnimationTrackUtil.NewFreezeGuard()
			local track = newFakeTrack()

			freeze(guard, { track }, FREEZE_SECONDS)
			task.wait(SETTLE_SECONDS)

			expect(track.Speed).to.equal(1)
		end)

		it("preserves a non-default authored speed rather than assuming 1", function()
			local guard = AnimationTrackUtil.NewFreezeGuard()
			local track = newFakeTrack(1.35)

			freeze(guard, { track }, FREEZE_SECONDS)
			task.wait(SETTLE_SECONDS)

			expect(track.Speed).to.equal(1.35)
		end)

		-- Defect (a). This is the one that fired constantly in real play: HitStop's throttle
		-- (Constants.FX.HitStop.MinIntervalSeconds, 0.1) is SHORTER than ParrySeconds/
		-- PostureBreakSeconds/VictimSeconds+HeavyBonusSeconds/FlightLandingHardSeconds, so any of
		-- those holds could be overlapped by the next impact by construction -- after which every
		-- combat track sat at speed 0 permanently.
		it("restores the true pre-freeze speed when a second freeze overlaps the first", function()
			local guard = AnimationTrackUtil.NewFreezeGuard()
			local track = newFakeTrack()

			freeze(guard, { track }, FREEZE_SECONDS)
			-- Well inside the first hold, so the second freeze samples an already-zeroed track.
			task.wait(FREEZE_SECONDS / 2)
			expect(track.Speed).to.equal(0)
			freeze(guard, { track }, FREEZE_SECONDS)

			task.wait(SETTLE_SECONDS)
			expect(track.Speed).to.equal(1)
		end)

		it("keeps the track frozen until the LATEST overlapping freeze elapses", function()
			local guard = AnimationTrackUtil.NewFreezeGuard()
			local track = newFakeTrack()

			freeze(guard, { track }, FREEZE_SECONDS)
			task.wait(FREEZE_SECONDS * 0.75)
			freeze(guard, { track }, FREEZE_SECONDS)
			-- Past when the FIRST freeze's own timer would have fired: the stale timer must not
			-- resume playback early while the newer freeze is still holding.
			task.wait(FREEZE_SECONDS * 0.5)

			expect(track.Speed).to.equal(0)
		end)

		it("survives three chained overlapping freezes", function()
			local guard = AnimationTrackUtil.NewFreezeGuard()
			local track = newFakeTrack()

			for _ = 1, 3 do
				freeze(guard, { track }, FREEZE_SECONDS)
				task.wait(FREEZE_SECONDS / 2)
			end

			task.wait(SETTLE_SECONDS)
			expect(track.Speed).to.equal(1)
		end)

		-- Defect (b). A hit-stop landing while the locomotion evaluator crossfades Walking out, or
		-- a swing clip completing under the freeze, both stop a frozen track mid-hold.
		it("restores a track that stopped playing during the freeze window", function()
			local guard = AnimationTrackUtil.NewFreezeGuard()
			local track = newFakeTrack()

			freeze(guard, { track }, FREEZE_SECONDS)
			track.IsPlaying = false
			task.wait(SETTLE_SECONDS)

			-- Speed persists across Stop()/Play() on a real AnimationTrack, so leaving this at 0
			-- would mean the track plays frozen the next time it starts -- permanently.
			expect(track.Speed).to.equal(1)
		end)

		it("does not strand a pending restore when a later freeze finds nothing playing", function()
			local guard = AnimationTrackUtil.NewFreezeGuard()
			local held = newFakeTrack()
			local idle = newFakeTrack()
			idle.IsPlaying = false

			freeze(guard, { held }, FREEZE_SECONDS)
			-- A no-op freeze must not bump the generation, or it would orphan the pending restore
			-- above and leave `held` at speed 0 with nothing left to resume it.
			freeze(guard, { idle }, FREEZE_SECONDS)

			task.wait(SETTLE_SECONDS)
			expect(held.Speed).to.equal(1)
		end)

		it("keeps separate guard instances fully independent", function()
			local combatGuard = AnimationTrackUtil.NewFreezeGuard()
			local flightGuard = AnimationTrackUtil.NewFreezeGuard()
			local combatTrack = newFakeTrack()
			local flightTrack = newFakeTrack()

			freeze(combatGuard, { combatTrack }, FREEZE_SECONDS)
			-- An unrelated freeze on the OTHER family must not supersede the combat restore.
			freeze(flightGuard, { flightTrack }, FREEZE_SECONDS * 4)

			task.wait(SETTLE_SECONDS)
			expect(combatTrack.Speed).to.equal(1)
			expect(flightTrack.Speed).to.equal(1)
		end)
	end)

	describe("AnimationTrackUtil.DriveDominantLoop", function()
		it("plays a newly-eligible track and re-asserts its weight while it keeps playing", function()
			local played: { number } = {}
			local weights: { number } = {}
			local track = {
				IsPlaying = false,
				Play = function(self: any, fade: number, weight: number): ()
					self.IsPlaying = true
					table.insert(played, fade)
					table.insert(weights, weight)
				end,
				AdjustWeight = function(_self: any, weight: number): ()
					table.insert(weights, weight)
				end,
				Stop = function(self: any, _fade: number): ()
					self.IsPlaying = false
				end,
			}

			local entries = {
				{ Track = track :: any, ShouldPlay = true, PlayFadeSeconds = 0.2, StopFadeSeconds = 0.03 },
			}
			AnimationTrackUtil.DriveDominantLoop(entries :: any, 100)
			-- Second tick: already playing, so no second Play() -- only another weight re-assert.
			AnimationTrackUtil.DriveDominantLoop(entries :: any, 100)

			expect(#played).to.equal(1)
			expect(played[1]).to.equal(0.2)
			expect(#weights).to.equal(3)
			expect(weights[3]).to.equal(100)
		end)

		it("stops a track that just became ineligible, using its stop fade", function()
			local stoppedWith: number? = nil
			local track = {
				IsPlaying = true,
				Play = function(self: any, _fade: number, _weight: number): ()
					self.IsPlaying = true
				end,
				AdjustWeight = function(_self: any, _weight: number): () end,
				Stop = function(self: any, fade: number): ()
					self.IsPlaying = false
					stoppedWith = fade
				end,
			}

			AnimationTrackUtil.DriveDominantLoop(
				{
					{ Track = track :: any, ShouldPlay = false, PlayFadeSeconds = 0.2, StopFadeSeconds = 0.03 },
				} :: any,
				100
			)

			expect(track.IsPlaying).to.equal(false)
			expect(stoppedWith).to.equal(0.03)
		end)

		it("skips nil track slots (an unauthored/empty animation id) without erroring", function()
			expect(function()
				AnimationTrackUtil.DriveDominantLoop(
					{
						{ Track = nil, ShouldPlay = true, PlayFadeSeconds = 0.2, StopFadeSeconds = 0.03 },
					} :: any,
					100
				)
			end).never.to.throw()
		end)
	end)
end
