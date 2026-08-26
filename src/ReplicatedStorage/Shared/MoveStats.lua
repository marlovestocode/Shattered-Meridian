--!strict
--[[
	MoveStats.lua

	Owns: every derived number the Move Editor's statistics/graph panel shows about a move, as pure
	functions over a MoveTypes.MoveDefinition. Two independent halves, deliberately in one module
	because the editor draws them on the same axes and they must agree on units and time origin:

	  * Project(move)          -- the THEORETICAL profile: what this move can do, computed straight
	                              from the authored numbers. Damage per hit, total across the target
	                              cap, the object-stun bonus and follow-up hit if configured, burst
	                              vs sustained DPS, when the first and last hit can land, reach and
	                              covered volume, and a cumulative-damage series to plot.
	  * SummarizeSamples(...)  -- the OBSERVED profile: the same shape, accumulated from real
	                              Combat_FeedbackEvent results while the admin test-fires the move,
	                              so the graph fills in against the projection instead of the author
	                              hand-calculating whether the move did what they intended.

	Time origin for both is the moment the move is thrown (t = 0), matching
	AnimationTimeline/HitboxResolver's own convention, so a damage marker and an animation clip
	drawn on the same strip line up.

	Everything here is an ESTIMATE and says so where it matters. A projected hit count assumes the
	move actually connects with MaxTargets distinct targets -- the real number depends on who is
	standing where. What the projection is exact about is the timing envelope (a hit cannot land
	before WindupSeconds or after WindupSeconds + ActiveSeconds, because HitboxResolver structurally
	only samples in that window) and the per-hit damage, since those come straight from the same
	fields the server reads.

	Does not own: the drawing (Components/Graph.lua), the panel (Screens/DevTools/MoveEditor/StatsPanel.lua),
	or any notion of balance -- nothing here judges whether a number is good, it only reports it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local HitboxShapes = require(ReplicatedStorage.Shared.HitboxShapes)
local AnimationTimeline = require(ReplicatedStorage.Shared.AnimationTimeline)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)

local MoveStats = {}

-- Where a projected damage instance comes from. Kept as a closed union so the graph can colour a
-- follow-up's contribution differently from the primary hit's without string-matching a label.
export type DamageEventSource = "Primary" | "ObjectStun" | "FollowUp"

export type DamageEvent = {
	Label: string,
	Source: DamageEventSource,
	-- Seconds from the throw. For the primary hit this is the EARLIEST it can land (the start of
	-- the active window) -- see this file's header on what the projection is and isn't exact about.
	TimeSeconds: number,
	Damage: number,
	PostureDamage: number,
	-- How many distinct targets this event can apply to (MaxTargets for the primary hit, 1 for the
	-- object-stun bonus, the follow-up's own cap for a follow-up).
	TargetCount: number,
}

export type SeriesPoint = {
	Time: number,
	Value: number,
}

export type PhaseSlice = {
	Phase: string,
	Seconds: number,
	Fraction: number,
}

export type MoveStatsReport = {
	WindupSeconds: number,
	ActiveSeconds: number,
	RecoverySeconds: number,
	CooldownSeconds: number,
	-- Move duration, and then the full span the graph must cover -- those differ whenever an
	-- object-stun follow-up lands after the parent move's own recovery has ended.
	TotalDurationSeconds: number,
	TimelineSeconds: number,

	ActiveWindowStart: number,
	ActiveWindowEnd: number,
	-- Earliest and latest a hit can land. Equal to the active window for a melee move; a projectile
	-- pushes the earliest later (it has to travel) and may end sooner (it expires at MaxRange).
	FirstHitSeconds: number,
	LastHitSeconds: number,

	DamagePerHit: number,
	PosturePerHit: number,
	MaxHits: number,
	-- What ONE target can take across the whole move, including an object-stun bonus and follow-up.
	SingleTargetDamage: number,
	SingleTargetPosture: number,
	-- What the move can deal in total if every hit finds a distinct target at its own cap.
	MaxTotalDamage: number,
	MaxTotalPosture: number,

	-- Total damage over the move's own duration (how hard the swing hits while it's happening)...
	BurstDamagePerSecond: number,
	-- ...versus over its cooldown (how hard it hits over time if spammed on cooldown). Sustained is
	-- the one that matters for balance; burst is the one that matters for feel.
	SustainedDamagePerSecond: number,
	SustainedPosturePerSecond: number,

	ReachStuds: number,
	VolumeStuds3: number,
	AnimationClipCount: number,

	Events: { DamageEvent },
	-- Cumulative single-target damage against time, ready to plot.
	CumulativeSeries: { SeriesPoint },
	PhaseBreakdown: { PhaseSlice },
}

-- One real result observed during a test fire, recorded by the editor client from the existing
-- Combat_FeedbackEvent stream. TimeSeconds is measured from when the test was fired, so an observed
-- marker can be drawn on the same axis as the projection.
export type TestSample = {
	TimeSeconds: number,
	Damage: number,
	PostureDamage: number,
	Kind: string,
}

export type TestSummary = {
	HitCount: number,
	TotalDamage: number,
	TotalPosture: number,
	PeakDamage: number,
	AverageDamage: number,
	FirstHitSeconds: number,
	LastHitSeconds: number,
	CumulativeSeries: { SeriesPoint },
}

-- Resolution of the plotted cumulative curve. 48 points is enough that a step at a damage event
-- reads as a step rather than a ramp at the panel's own graph width, while staying cheap enough to
-- recompute on every keystroke in a numeric field.
local SERIES_SAMPLES = 48

local function round(value: number, decimals: number): number
	local scale = 10 ^ decimals
	return math.floor(value * scale + 0.5) / scale
end

-- Cumulative damage at `time`, summing every event at or before it. O(events) per sample, with a
-- handful of events and 48 samples -- not worth an accumulating sweep's extra state.
local function cumulativeAt(events: { DamageEvent }, time: number): number
	local total = 0
	for _, event in ipairs(events) do
		if event.TimeSeconds <= time then
			total += event.Damage
		end
	end
	return total
end

local function buildSeries(events: { DamageEvent }, span: number): { SeriesPoint }
	local series: { SeriesPoint } = {}
	local safeSpan = math.max(span, 0.001)
	for index = 0, SERIES_SAMPLES do
		local time = safeSpan * index / SERIES_SAMPLES
		table.insert(series, { Time = time, Value = cumulativeAt(events, time) })
	end
	return series
end

-- The projected profile of a move -- see this file's header for what is exact and what is an
-- estimate. Total over the whole definition, never partial: a move with no knockback, no object
-- stun and no follow-up simply reports a one-event timeline.
function MoveStats.Project(move: MoveTypes.MoveDefinition): MoveStatsReport
	local windup = move.WindupSeconds
	local active = move.ActiveSeconds
	local recovery = move.RecoverySeconds
	local totalDuration = windup + active + recovery

	local activeStart = windup
	local activeEnd = windup + active

	-- A projectile can't hit at the instant it launches -- it has to cross its own hitbox's reach
	-- first -- and it stops existing at MaxRange even if ActiveSeconds hasn't elapsed, exactly as
	-- HitboxResolver.Update's own maxFlightSeconds cap does. Mirrored here so the graph's hit
	-- window matches what the server will actually schedule.
	local firstHit = activeStart
	local lastHit = activeEnd
	if move.Projectile then
		local flightCap = math.min(active, move.Projectile.MaxRange / move.Projectile.Speed)
		lastHit = activeStart + flightCap
	end

	local maxTargets = math.max(move.MaxTargets or 1, 1)
	local events: { DamageEvent } = {}

	table.insert(events, {
		Label = "Hit",
		Source = "Primary",
		TimeSeconds = firstHit,
		Damage = move.Damage,
		PostureDamage = move.PostureDamage,
		TargetCount = maxTargets,
	})

	local objectStun = move.ObjectStun
	if objectStun and objectStun.Enabled then
		-- The impact can't happen before the hit that launched the target, and MaxTravelSeconds is
		-- the outside limit the resolver will keep watching for it -- but a realistic impact lands
		-- well inside that. Half the watch window is the honest midpoint to plot, and the readout
		-- labels it as an estimate.
		local impactAt = firstHit + math.min(objectStun.MaxTravelSeconds, 1) * 0.5
		if objectStun.BonusDamage > 0 or objectStun.BonusPostureDamage > 0 then
			table.insert(events, {
				Label = "Object stun",
				Source = "ObjectStun",
				TimeSeconds = impactAt,
				Damage = objectStun.BonusDamage,
				PostureDamage = objectStun.BonusPostureDamage,
				TargetCount = 1,
			})
		end

		local followUp = objectStun.FollowUp
		if followUp and followUp.Enabled then
			table.insert(events, {
				Label = "Follow-up",
				Source = "FollowUp",
				TimeSeconds = impactAt + followUp.DelaySeconds + followUp.WindupSeconds,
				Damage = followUp.Damage,
				PostureDamage = followUp.PostureDamage,
				TargetCount = math.max(followUp.MaxTargets, 1),
			})
		end
	end

	table.sort(events, function(a, b)
		return a.TimeSeconds < b.TimeSeconds
	end)

	local singleTargetDamage = 0
	local singleTargetPosture = 0
	local maxTotalDamage = 0
	local maxTotalPosture = 0
	for _, event in ipairs(events) do
		singleTargetDamage += event.Damage
		singleTargetPosture += event.PostureDamage
		maxTotalDamage += event.Damage * event.TargetCount
		maxTotalPosture += event.PostureDamage * event.TargetCount
	end

	local latestEvent = totalDuration
	for _, event in ipairs(events) do
		if event.TimeSeconds > latestEvent then
			latestEvent = event.TimeSeconds
		end
	end
	local timelineSeconds = math.max(totalDuration, latestEvent)

	-- Cooldown is measured from the throw, so a cooldown shorter than the move's own duration means
	-- the move gates on its duration instead -- the same relationship HitboxAttackDefinition
	-- .RecoverySeconds' own tuning note describes.
	local cycleSeconds = math.max(move.Cooldown, totalDuration, 0.001)

	local phases: { PhaseSlice } = {}
	local function addPhase(name: string, seconds: number)
		table.insert(phases, {
			Phase = name,
			Seconds = seconds,
			Fraction = if totalDuration > 0 then seconds / totalDuration else 0,
		})
	end
	addPhase("Windup", windup)
	addPhase("Active", active)
	addPhase("Recovery", recovery)

	local dimensions = move.Dimensions

	return {
		WindupSeconds = windup,
		ActiveSeconds = active,
		RecoverySeconds = recovery,
		CooldownSeconds = move.Cooldown,
		TotalDurationSeconds = totalDuration,
		TimelineSeconds = timelineSeconds,

		ActiveWindowStart = activeStart,
		ActiveWindowEnd = activeEnd,
		FirstHitSeconds = firstHit,
		LastHitSeconds = lastHit,

		DamagePerHit = move.Damage,
		PosturePerHit = move.PostureDamage,
		MaxHits = maxTargets,
		SingleTargetDamage = singleTargetDamage,
		SingleTargetPosture = singleTargetPosture,
		MaxTotalDamage = maxTotalDamage,
		MaxTotalPosture = maxTotalPosture,

		BurstDamagePerSecond = round(singleTargetDamage / math.max(totalDuration, 0.001), 2),
		SustainedDamagePerSecond = round(singleTargetDamage / cycleSeconds, 2),
		SustainedPosturePerSecond = round(singleTargetPosture / cycleSeconds, 2),

		ReachStuds = round(HitboxShapes.Reach(move.Shape, dimensions), 2),
		VolumeStuds3 = round(HitboxShapes.ApproximateVolume(move.Shape, dimensions), 1),
		AnimationClipCount = #AnimationTimeline.Resolve(move.Animations, {
			WindupSeconds = windup,
			ActiveSeconds = active,
			RecoverySeconds = recovery,
		}),

		Events = events,
		CumulativeSeries = buildSeries(events, timelineSeconds),
		PhaseBreakdown = phases,
	}
end

-- The observed counterpart of Project, over whatever real results a test fire produced. Returns a
-- zeroed summary for an empty sample list rather than nil, so the panel renders "0 hits" instead of
-- having to branch on a missing report.
function MoveStats.SummarizeSamples(samples: { TestSample }, spanSeconds: number): TestSummary
	if #samples == 0 then
		return {
			HitCount = 0,
			TotalDamage = 0,
			TotalPosture = 0,
			PeakDamage = 0,
			AverageDamage = 0,
			FirstHitSeconds = 0,
			LastHitSeconds = 0,
			CumulativeSeries = {},
		}
	end

	local ordered = table.clone(samples)
	table.sort(ordered, function(a, b)
		return a.TimeSeconds < b.TimeSeconds
	end)

	local totalDamage = 0
	local totalPosture = 0
	local peak = 0
	for _, sample in ipairs(ordered) do
		totalDamage += sample.Damage
		totalPosture += sample.PostureDamage
		if sample.Damage > peak then
			peak = sample.Damage
		end
	end

	local first = ordered[1].TimeSeconds
	local last = ordered[#ordered].TimeSeconds
	local span = math.max(spanSeconds, last, 0.001)

	-- Reuses the projection's own sampler by projecting each observed hit into the same DamageEvent
	-- shape -- one curve builder means the observed and projected lines are guaranteed to share an
	-- x-axis and a sample count, which is the only way overlaying them reads correctly.
	local asEvents: { DamageEvent } = {}
	for _, sample in ipairs(ordered) do
		table.insert(asEvents, {
			Label = sample.Kind,
			Source = "Primary",
			TimeSeconds = sample.TimeSeconds,
			Damage = sample.Damage,
			PostureDamage = sample.PostureDamage,
			TargetCount = 1,
		})
	end

	return {
		HitCount = #ordered,
		TotalDamage = totalDamage,
		TotalPosture = totalPosture,
		PeakDamage = peak,
		AverageDamage = round(totalDamage / #ordered, 2),
		FirstHitSeconds = round(first, 3),
		LastHitSeconds = round(last, 3),
		CumulativeSeries = buildSeries(asEvents, span),
	}
end

return MoveStats
