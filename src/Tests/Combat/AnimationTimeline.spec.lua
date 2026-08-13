--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnimationTimeline = require(ReplicatedStorage.Shared.AnimationTimeline)

type Clip = AnimationTimeline.Clip

-- Windup 0.2 / Active 0.3 / Recovery 0.4, so total is 0.9 and every phase boundary is a distinct,
-- easily-named number: Active starts at 0.2 and ends at 0.5.
local TIMINGS: AnimationTimeline.PhaseTimings = {
	WindupSeconds = 0.2,
	ActiveSeconds = 0.3,
	RecoverySeconds = 0.4,
}

local EPSILON = 1e-6

local function nearly(actual: number, expected: number): boolean
	return math.abs(actual - expected) < EPSILON
end

-- A clip that will actually be scheduled (Enabled, with a non-empty AnimationId), built off
-- DefaultClip so a test only states the fields it is actually about.
local function makeClip(order: number, overrides: { [string]: any }?): Clip
	local clip = AnimationTimeline.DefaultClip("clip" .. tostring(order), order, "rbxassetid://1")
	for key, value in pairs(overrides or {}) do
		(clip :: any)[key] = value
	end
	return clip
end

return function()
	describe("AnimationTimeline phase helpers", function()
		it("reports the total as the sum of the three phases", function()
			expect(nearly(AnimationTimeline.TotalDuration(TIMINGS), 0.9)).to.equal(true)
		end)

		it("reports each phase's own start and end", function()
			expect(AnimationTimeline.PhaseStart(TIMINGS, "Windup")).to.equal(0)
			expect(nearly(AnimationTimeline.PhaseStart(TIMINGS, "Active"), 0.2)).to.equal(true)
			expect(nearly(AnimationTimeline.PhaseStart(TIMINGS, "Recovery"), 0.5)).to.equal(true)

			expect(nearly(AnimationTimeline.PhaseEnd(TIMINGS, "Windup"), 0.2)).to.equal(true)
			expect(nearly(AnimationTimeline.PhaseEnd(TIMINGS, "Active"), 0.5)).to.equal(true)
			expect(nearly(AnimationTimeline.PhaseEnd(TIMINGS, "Recovery"), 0.9)).to.equal(true)
		end)

		it("maps an elapsed time onto its phase, clamping past the end to Recovery", function()
			expect(AnimationTimeline.PhaseAt(TIMINGS, 0)).to.equal("Windup")
			expect(AnimationTimeline.PhaseAt(TIMINGS, 0.19)).to.equal("Windup")
			expect(AnimationTimeline.PhaseAt(TIMINGS, 0.2)).to.equal("Active")
			expect(AnimationTimeline.PhaseAt(TIMINGS, 0.49)).to.equal("Active")
			expect(AnimationTimeline.PhaseAt(TIMINGS, 0.5)).to.equal("Recovery")
			-- Past the move's own end is a routine floating-point occurrence for a caller drawing a
			-- scrubber, not an error condition.
			expect(AnimationTimeline.PhaseAt(TIMINGS, 99)).to.equal("Recovery")
		end)
	end)

	describe("AnimationTimeline.NextClipId", function()
		it("starts at clip1 for an empty list", function()
			expect(AnimationTimeline.NextClipId({})).to.equal("clip1")
		end)

		-- Derived from the highest existing suffix rather than the COUNT, so deleting out of the
		-- middle of a list cannot produce an id that collides with a survivor.
		it("derives from the highest suffix, not the clip count", function()
			local clips = { makeClip(1), makeClip(2), makeClip(3) }
			table.remove(clips, 2)
			expect(#clips).to.equal(2)
			expect(AnimationTimeline.NextClipId(clips)).to.equal("clip4")
		end)

		it("ignores an id that does not match the clipN form", function()
			local clip = makeClip(1)
			clip.ClipId = "legacy"
			expect(AnimationTimeline.NextClipId({ clip })).to.equal("clip1")
		end)
	end)

	describe("AnimationTimeline.FromLegacyAnimationId", function()
		it("treats the empty id as no clips at all", function()
			expect(#AnimationTimeline.FromLegacyAnimationId("")).to.equal(0)
		end)

		-- The projection has to be behaviour-preserving: a v1 move's single clip must start at t=0 and
		-- play itself out, which is exactly what the pre-timeline runtime did with that id.
		it("projects a single id onto one clip that starts at zero and plays out", function()
			local clips = AnimationTimeline.FromLegacyAnimationId("rbxassetid://42")
			expect(#clips).to.equal(1)
			local clip = clips[1]
			expect(clip.AnimationId).to.equal("rbxassetid://42")
			expect(clip.Name).to.equal("Main")
			expect(clip.Enabled).to.equal(true)
			expect(clip.StartMode).to.equal("Time")
			expect(clip.StartTime).to.equal(0)
			expect(clip.StopMode).to.equal("Natural")
			expect(clip.Speed).to.equal(1)
			expect(clip.Weight).to.equal(1)
		end)
	end)

	describe("AnimationTimeline.SanitizeClip", function()
		it("returns the default clip for a non-table input", function()
			local clip = AnimationTimeline.SanitizeClip("nonsense", "clip1", 1)
			expect(clip.ClipId).to.equal("clip1")
			expect(clip.Order).to.equal(1)
			expect(clip.AnimationId).to.equal("")
		end)

		it("clamps every numeric field into its limit", function()
			local limits = AnimationTimeline.Limits
			local clip = AnimationTimeline.SanitizeClip({
				StartTime = 1e6,
				StartDelay = -5,
				DurationSeconds = 1e6,
				Speed = 1e6,
				Weight = -1,
				FadeInSeconds = 1e6,
				FadeOutSeconds = -1,
			}, "clip1", 1)
			expect(clip.StartTime).to.equal(limits.MaxStartTime)
			expect(clip.StartDelay).to.equal(limits.MinStartDelay)
			expect(clip.DurationSeconds).to.equal(limits.MaxDuration)
			expect(clip.Speed).to.equal(limits.MaxSpeed)
			expect(clip.Weight).to.equal(limits.MinWeight)
			expect(clip.FadeInSeconds).to.equal(limits.MaxFade)
			expect(clip.FadeOutSeconds).to.equal(limits.MinFade)
		end)

		it("falls back on an unrecognized enum rather than propagating it", function()
			local clip = AnimationTimeline.SanitizeClip({
				StartMode = "Whenever",
				StopMode = "Eventually",
				Blend = "Somehow",
				OnInterrupt = "Maybe",
				StartPhase = "Midair",
			}, "clip1", 1)
			expect(clip.StartMode).to.equal("Time")
			expect(clip.StopMode).to.equal("Natural")
			expect(clip.Blend).to.equal("Overlap")
			expect(clip.OnInterrupt).to.equal("Stop")
			expect(clip.StartPhase).to.equal("Windup")
		end)

		it("rejects NaN, which survives a comparison-based clamp", function()
			local clip = AnimationTimeline.SanitizeClip({ Speed = 0 / 0 }, "clip1", 1)
			expect(clip.Speed).to.equal(1)
		end)

		it("truncates an over-long name and animation id", function()
			local limits = AnimationTimeline.Limits
			local clip = AnimationTimeline.SanitizeClip({
				Name = string.rep("x", limits.MaxNameLength + 50),
				AnimationId = string.rep("y", limits.MaxAnimationIdLength + 50),
			}, "clip1", 1)
			expect(#clip.Name).to.equal(limits.MaxNameLength)
			expect(#clip.AnimationId).to.equal(limits.MaxAnimationIdLength)
		end)
	end)

	describe("AnimationTimeline.Sanitize", function()
		it("returns no clips for a non-table input", function()
			expect(#AnimationTimeline.Sanitize(nil)).to.equal(0)
			expect(#AnimationTimeline.Sanitize("nonsense")).to.equal(0)
		end)

		it("caps the list at MaxClips, dropping the overflow", function()
			local raw = {}
			for index = 1, AnimationTimeline.Limits.MaxClips + 5 do
				raw[index] = { AnimationId = "rbxassetid://" .. tostring(index) }
			end
			expect(#AnimationTimeline.Sanitize(raw)).to.equal(AnimationTimeline.Limits.MaxClips)
		end)

		-- Ids are re-derived positionally so a client can never submit two clips sharing one id and
		-- confuse the editor's own per-row state.
		it("re-derives clip ids positionally, breaking a submitted duplicate", function()
			local clips = AnimationTimeline.Sanitize({
				{ ClipId = "same", AnimationId = "rbxassetid://1" },
				{ ClipId = "same", AnimationId = "rbxassetid://2" },
			})
			expect(#clips).to.equal(2)
			expect(clips[1].ClipId).to.equal("clip1")
			expect(clips[2].ClipId).to.equal("clip2")
		end)
	end)

	describe("AnimationTimeline.Resolve", function()
		it("returns an empty schedule for an empty clip list", function()
			expect(#AnimationTimeline.Resolve({}, TIMINGS)).to.equal(0)
		end)

		it("drops disabled clips and clips with no animation id", function()
			local scheduled = AnimationTimeline.Resolve({
				makeClip(1, { Enabled = false }),
				makeClip(2, { AnimationId = "" }),
				makeClip(3),
			}, TIMINGS)
			expect(#scheduled).to.equal(1)
			expect(scheduled[1].Clip.ClipId).to.equal("clip3")
		end)

		it("plays clips in Order, not authored position", function()
			local scheduled = AnimationTimeline.Resolve({
				makeClip(1, { Order = 5 }),
				makeClip(2, { Order = 2 }),
			}, TIMINGS)
			expect(scheduled[1].Clip.ClipId).to.equal("clip2")
			expect(scheduled[2].Clip.ClipId).to.equal("clip1")
			expect(scheduled[1].Index).to.equal(1)
			expect(scheduled[2].Index).to.equal(2)
		end)

		-- A non-stable sort would make the preview flicker between two orderings across frames.
		it("keeps the authored order as a stable tiebreak when Order ties", function()
			local first = makeClip(1, { Order = 3 })
			local second = makeClip(2, { Order = 3 })
			local scheduled = AnimationTimeline.Resolve({ first, second }, TIMINGS)
			expect(scheduled[1].Clip.ClipId).to.equal("clip1")
			expect(scheduled[2].Clip.ClipId).to.equal("clip2")
		end)

		it("starts a Time clip at its own StartTime plus its delay", function()
			local scheduled = AnimationTimeline.Resolve({
				makeClip(1, { StartMode = "Time", StartTime = 0.1, StartDelay = 0.05 }),
			}, TIMINGS)
			expect(nearly(scheduled[1].StartSeconds, 0.15)).to.equal(true)
		end)

		it("starts a Phase clip at that phase's own start", function()
			local scheduled = AnimationTimeline.Resolve({
				makeClip(1, { StartMode = "Phase", StartPhase = "Active" }),
				makeClip(2, { StartMode = "Phase", StartPhase = "Recovery", Order = 2 }),
			}, TIMINGS)
			expect(nearly(scheduled[1].StartSeconds, 0.2)).to.equal(true)
			expect(nearly(scheduled[2].StartSeconds, 0.5)).to.equal(true)
		end)

		it("starts an AfterPrevious clip where the previous one stopped", function()
			local scheduled = AnimationTimeline.Resolve({
				makeClip(1, { StartMode = "Time", StartTime = 0, StopMode = "Duration", DurationSeconds = 0.25 }),
				makeClip(2, { Order = 2, StartMode = "AfterPrevious" }),
			}, TIMINGS)
			expect(nearly(scheduled[1].StopSeconds, 0.25)).to.equal(true)
			expect(nearly(scheduled[2].StartSeconds, 0.25)).to.equal(true)
		end)

		it("clamps a start beyond the move's own end back onto it", function()
			local scheduled = AnimationTimeline.Resolve({
				makeClip(1, { StartMode = "Time", StartTime = 5 }),
			}, TIMINGS)
			expect(nearly(scheduled[1].StartSeconds, 0.9)).to.equal(true)
		end)

		it("honours each stop mode", function()
			local scheduled = AnimationTimeline.Resolve({
				makeClip(1, { StartTime = 0.1, StopMode = "Duration", DurationSeconds = 0.15 }),
				makeClip(2, { Order = 2, StartTime = 0.25, StopMode = "PhaseEnd" }),
				makeClip(3, { Order = 3, StartTime = 0.1, StopMode = "MoveEnd" }),
				makeClip(4, { Order = 4, StartTime = 0.1, StopMode = "Natural" }),
			}, TIMINGS)

			expect(nearly(scheduled[1].StopSeconds, 0.25)).to.equal(true)
			expect(scheduled[1].StoppedBy).to.equal("Duration")
			-- 0.25 lands in Active, whose end is 0.5.
			expect(nearly(scheduled[2].StopSeconds, 0.5)).to.equal(true)
			expect(scheduled[2].StoppedBy).to.equal("PhaseEnd")
			expect(nearly(scheduled[3].StopSeconds, 0.9)).to.equal(true)
			expect(scheduled[3].StoppedBy).to.equal("MoveEnd")
			expect(nearly(scheduled[4].StopSeconds, 0.9)).to.equal(true)
			expect(scheduled[4].StoppedBy).to.equal("Natural")
		end)

		-- LetPlayOut is what tells a runtime to skip the scheduled Stop entirely; StopSeconds for a
		-- Natural clip is a drawing/statistics bound only.
		it("marks only a Natural clip as playing itself out", function()
			local scheduled = AnimationTimeline.Resolve({
				makeClip(1, { StopMode = "Natural" }),
				makeClip(2, { Order = 2, StopMode = "MoveEnd" }),
			}, TIMINGS)
			expect(scheduled[1].LetPlayOut).to.equal(true)
			expect(scheduled[2].LetPlayOut).to.equal(false)
		end)

		it("uses the phase a clip actually starts in for PhaseEnd, not its authored StartPhase", function()
			-- Authored to start in Windup, but the delay pushes it into Active -- so it should end with
			-- Active (0.5), the phase it is really playing over.
			local scheduled = AnimationTimeline.Resolve({
				makeClip(1, { StartMode = "Phase", StartPhase = "Windup", StartDelay = 0.25, StopMode = "PhaseEnd" }),
			}, TIMINGS)
			expect(nearly(scheduled[1].StartSeconds, 0.25)).to.equal(true)
			expect(nearly(scheduled[1].StopSeconds, 0.5)).to.equal(true)
		end)

		describe("Queue", function()
			it("pushes a clip later when it would otherwise start before the previous one stopped", function()
				local scheduled = AnimationTimeline.Resolve({
					makeClip(1, { StartTime = 0, StopMode = "Duration", DurationSeconds = 0.5 }),
					makeClip(2, { Order = 2, StartTime = 0.1, Blend = "Queue" }),
				}, TIMINGS)
				expect(nearly(scheduled[2].StartSeconds, 0.5)).to.equal(true)
				expect(scheduled[2].DelayedByQueue).to.equal(true)
			end)

			it("never pulls a clip earlier than its own timing asked for", function()
				local scheduled = AnimationTimeline.Resolve({
					makeClip(1, { StartTime = 0, StopMode = "Duration", DurationSeconds = 0.1 }),
					makeClip(2, { Order = 2, StartTime = 0.6, Blend = "Queue" }),
				}, TIMINGS)
				expect(nearly(scheduled[2].StartSeconds, 0.6)).to.equal(true)
				expect(scheduled[2].DelayedByQueue).to.equal(false)
			end)

			it("leaves an Overlap clip free to start whenever its own timing says", function()
				local scheduled = AnimationTimeline.Resolve({
					makeClip(1, { StartTime = 0, StopMode = "Duration", DurationSeconds = 0.5 }),
					makeClip(2, { Order = 2, StartTime = 0.1, Blend = "Overlap" }),
				}, TIMINGS)
				expect(nearly(scheduled[2].StartSeconds, 0.1)).to.equal(true)
				expect(scheduled[2].DelayedByQueue).to.equal(false)
			end)
		end)

		describe("Exclusive", function()
			it("truncates an earlier clip still running when it starts", function()
				local scheduled = AnimationTimeline.Resolve({
					makeClip(1, { StartTime = 0, StopMode = "Duration", DurationSeconds = 0.8 }),
					makeClip(2, { Order = 2, StartTime = 0.3, Blend = "Exclusive" }),
				}, TIMINGS)
				expect(nearly(scheduled[1].StopSeconds, 0.3)).to.equal(true)
				expect(nearly(scheduled[1].DurationSeconds, 0.3)).to.equal(true)
				expect(scheduled[1].StoppedBy).to.equal("Exclusive")
				-- A truncated clip is no longer playing itself out, whatever its own StopMode said.
				expect(scheduled[1].LetPlayOut).to.equal(false)
			end)

			it("overrides a Natural clip's own let-it-play-out", function()
				local scheduled = AnimationTimeline.Resolve({
					makeClip(1, { StartTime = 0, StopMode = "Natural" }),
					makeClip(2, { Order = 2, StartTime = 0.4, Blend = "Exclusive" }),
				}, TIMINGS)
				expect(scheduled[1].LetPlayOut).to.equal(false)
				expect(nearly(scheduled[1].StopSeconds, 0.4)).to.equal(true)
			end)

			it("leaves an earlier clip that had already finished alone", function()
				local scheduled = AnimationTimeline.Resolve({
					makeClip(1, { StartTime = 0, StopMode = "Duration", DurationSeconds = 0.2 }),
					makeClip(2, { Order = 2, StartTime = 0.5, Blend = "Exclusive" }),
				}, TIMINGS)
				expect(nearly(scheduled[1].StopSeconds, 0.2)).to.equal(true)
				expect(scheduled[1].StoppedBy).to.equal("Duration")
			end)

			it("does not truncate a LATER-ordered clip", function()
				local scheduled = AnimationTimeline.Resolve({
					makeClip(1, { StartTime = 0.3, Blend = "Exclusive" }),
					makeClip(2, { Order = 2, StartTime = 0.4, StopMode = "MoveEnd" }),
				}, TIMINGS)
				expect(nearly(scheduled[2].StopSeconds, 0.9)).to.equal(true)
				expect(scheduled[2].StoppedBy).to.equal("MoveEnd")
			end)
		end)

		it("never produces a stop before its own start", function()
			local scheduled = AnimationTimeline.Resolve({
				makeClip(1, { StartMode = "Time", StartTime = 0.8, StopMode = "PhaseEnd" }),
				makeClip(2, { Order = 2, StartMode = "Time", StartTime = 0.9, StopMode = "MoveEnd" }),
			}, TIMINGS)
			for _, entry in ipairs(scheduled) do
				expect(entry.StopSeconds >= entry.StartSeconds).to.equal(true)
				expect(entry.DurationSeconds >= 0).to.equal(true)
			end
		end)
	end)

	describe("AnimationTimeline.ActiveAt", function()
		-- 0.25/0.5 rather than 0.1/0.3: these boundaries are compared for exact equality, and only a
		-- dyadic fraction survives the addition inside Resolve without picking up a last-bit error that
		-- would make "exclusive at the stop" look inclusive.
		it("is inclusive at the start and exclusive at the stop", function()
			local scheduled = AnimationTimeline.Resolve({
				makeClip(1, { StartTime = 0.25, StopMode = "Duration", DurationSeconds = 0.25 }),
			}, TIMINGS)
			expect(scheduled[1].StartSeconds).to.equal(0.25)
			expect(scheduled[1].StopSeconds).to.equal(0.5)

			expect(#AnimationTimeline.ActiveAt(scheduled, 0.2)).to.equal(0)
			expect(#AnimationTimeline.ActiveAt(scheduled, 0.25)).to.equal(1)
			expect(#AnimationTimeline.ActiveAt(scheduled, 0.375)).to.equal(1)
			-- Exclusive at the stop, so two back-to-back clips never both report live on the boundary.
			expect(#AnimationTimeline.ActiveAt(scheduled, 0.5)).to.equal(0)
		end)

		it("reports every overlapping clip at once", function()
			local scheduled = AnimationTimeline.Resolve({
				makeClip(1, { StartTime = 0, StopMode = "MoveEnd" }),
				makeClip(2, { Order = 2, StartTime = 0.1, StopMode = "MoveEnd", Blend = "Overlap" }),
			}, TIMINGS)
			expect(#AnimationTimeline.ActiveAt(scheduled, 0.05)).to.equal(1)
			expect(#AnimationTimeline.ActiveAt(scheduled, 0.2)).to.equal(2)
		end)
	end)

	describe("AnimationTimeline.ScheduleEnd", function()
		it("is zero for an empty schedule", function()
			expect(AnimationTimeline.ScheduleEnd({})).to.equal(0)
		end)

		it("reports the last moment any clip is still playing", function()
			local scheduled = AnimationTimeline.Resolve({
				makeClip(1, { StartTime = 0, StopMode = "Duration", DurationSeconds = 0.1 }),
				makeClip(2, { Order = 2, StartTime = 0.2, StopMode = "MoveEnd" }),
			}, TIMINGS)
			expect(nearly(AnimationTimeline.ScheduleEnd(scheduled), 0.9)).to.equal(true)
		end)
	end)
end
