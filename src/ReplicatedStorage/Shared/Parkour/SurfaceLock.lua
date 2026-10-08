--!strict
--[[
	SurfaceLock.lua

	Owns: deciding WHICH SURFACE a probe is describing, as a plane that persists from one sample to the next
	-- the memory the parkour probes did not have. Three pieces, all pure and Instance-free in their logic:

	  * CONSENSUS (SampleSet / Vote): several rays cast around one spot vote on what is there. The plane the
	    most rays agree on wins; a ray that disagrees with the rest -- a sliver of a part poking out of a wall,
	    a gap between two blocks, a part buried inside another -- is an outlier and is dropped.
	  * THE LOCK (Lock / Observe): the surface a probe is currently holding, stored as a POSITION and a NORMAL
	    with the part it was last seen on as a mere label. Each new candidate is compared to it and is
	    merged, held against, or allowed to take over.
	  * the small queries both need (Matches, Distance).

	WHY THIS EXISTS, in one paragraph. EnvironmentProbe used to answer "what is the wall beside me" by taking the
	nearest hit of one ray, fresh, every sample. On anything built from one big part that is fine. On a mountain
	-- a pile of overlapping and near-touching parts -- the nearest hit moves between parts as the character
	moves a fraction of a stud, so the wall-run's normal jittered, a seam between two blocks read as the wall
	ending, and a part barely sticking out of the real face would win a sample and seat the character in it.
	Two parts a hair apart "fought for possession" of the player. The cure is not to pick better parts; it is to
	stop treating the PART as the thing being attached to. A wall is a plane, and a plane survives the parts
	that compose it.

	THE DECISION TABLE for a candidate surface C against a held surface H (Observe), first match wins:

	    no candidate at all ............ H is dropped (Lost). Deliberately no grace period -- States/WallRunning's
	                                     corner turn relies on a lost wall being reported lost on the frame it goes.
	    no H, or H not confirmed lately  C is adopted (Acquired).
	    C and H are the SAME surface .... H follows C (Merged): the label moves to C's part, the contact point to
	                                     C's, the normal eases toward C's. No decision was made; one wall, many parts.
	    C is far BEHIND H's plane ....... H has receded out from under the character (a recess, the end of a
	                                     wall). C is adopted at once (Switched), with no cooldown.
	    C is clearly better, and the
	    switch cooldown has elapsed ..... C is adopted (Switched): nearer by SwitchDistance, or squarer by
	                                     SwitchSquarenessMargin, or turned by SharpNormalDegrees (a corner).
	    otherwise ....................... H STANDS (Held): C was noise. The contact point follows C but is
	                                     projected back onto H's plane, so the held surface keeps tracking the
	                                     character without ever adopting the bump.

	The numbers are ParkourConstants.Surface's; this module receives them as a `Config` parameter and requires
	no constants itself, the rule ParkourMath and FlightMath are held to and for the same reason: every case
	below is plain arithmetic a spec can run without a place.

	ALLOCATION. EnvironmentProbe runs these every Heartbeat for the whole session and holds itself to "no
	tables and no Vector3s per frame beyond what the engine returns". A SampleSet, a Consensus and a Lock are
	therefore each built ONCE (the New* constructors) and mutated in place forever after, and every function
	here that produces a result writes into a table the caller owns instead of returning a fresh one. The
	same read-immediately-never-retain contract as the probe result tables applies to all three.

	Does not own: casting a ray (EnvironmentProbe is the only module allowed to), the cluster geometry the
	rays are cast in (the probes know their own axes), permission tags (ParkourTagging -- a sample is only
	ever added for a hit the caller has already accepted), or what any state does with the surface.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ParkourMath = require(ReplicatedStorage.Shared.Parkour.ParkourMath)

local SurfaceLock = {}

local UP = Vector3.new(0, 1, 0)

--
-- Types
--

-- The fields of ParkourConstants.Surface this module reads. A structural type rather than a require of the
-- constants, so a spec can pass a literal and the module stays constant-free; EnvironmentProbe passes the
-- live table, which carries these names exactly.
export type ConsensusConfig = {
	AgreeAngleDegrees: number,
	AgreeOffsetStuds: number,
	MinSupport: number,
}

export type Config = {
	SameSurfaceAngleDegrees: number,
	SameSurfaceOffsetStuds: number,
	SwitchDistanceStuds: number,
	SwitchSquarenessMargin: number,
	SharpNormalDegrees: number,
	SwitchCooldownSeconds: number,
	LockExpirySeconds: number,
	NormalBlendRate: number,
	Consensus: ConsensusConfig,
}

-- One ray's contribution. `Distance` is how far along its own ray the hit was, carried so a consensus can
-- report a distance without the caller re-measuring.
export type Sample = {
	Position: Vector3,
	Normal: Vector3,
	Instance: BasePart?,
	Distance: number,
}

-- A fixed-capacity, reusable list of samples. `Count` is how many are live; entries past it are stale and
-- never read.
export type SampleSet = {
	Count: number,
	Items: { Sample },
}

-- The outcome of a vote. `Valid` false means no plane had enough support -- every other field is then stale.
export type Consensus = {
	Valid: boolean,
	Position: Vector3,
	Normal: Vector3,
	Instance: BasePart?,
	Distance: number,
	-- How many rays stood on the winning plane, out of how many hit anything. Published for the debug overlay:
	-- "2/5" and "5/5" are different levels of trust, and a rejection is only explicable with the numbers.
	Support: number,
	Total: number,
}

-- Anything with a place, a facing and a label -- both a Sample and a Consensus qualify, which is why
-- Observe takes this rather than either.
export type Candidate = {
	Position: Vector3,
	Normal: Vector3,
	Instance: BasePart?,
}

export type Verdict = "None" | "Acquired" | "Merged" | "Held" | "Switched" | "Lost"

export type Lock = {
	Held: boolean,
	Position: Vector3,
	Normal: Vector3,
	-- The part the surface was last seen on. A LABEL: it moves to whichever part the latest agreeing sample
	-- hit, and nothing about the held plane depends on it.
	Instance: BasePart?,
	HeldSince: number,
	-- When any sample last agreed with, or was absorbed by, this surface. LockExpirySeconds is measured
	-- from here.
	ConfirmedAt: number,
	SwitchLockedUntil: number,
	-- What the last Observe decided, for the debug overlay and for specs.
	Verdict: Verdict,
}

--
-- Constructors
--

function SurfaceLock.NewSampleSet(capacity: number): SampleSet
	local items: { Sample } = table.create(capacity)
	for index = 1, capacity do
		items[index] = { Position = Vector3.zero, Normal = UP, Instance = nil, Distance = 0 }
	end
	return { Count = 0, Items = items }
end

function SurfaceLock.NewConsensus(): Consensus
	return {
		Valid = false,
		Position = Vector3.zero,
		Normal = UP,
		Instance = nil,
		Distance = 0,
		Support = 0,
		Total = 0,
	}
end

function SurfaceLock.NewLock(): Lock
	return {
		Held = false,
		Position = Vector3.zero,
		Normal = UP,
		Instance = nil,
		HeldSince = 0,
		ConfirmedAt = 0,
		SwitchLockedUntil = 0,
		Verdict = "None",
	}
end

--
-- Consensus
--

function SurfaceLock.Clear(set: SampleSet): ()
	set.Count = 0
end

-- Appends one ray's hit. A set that is already full ignores the sample rather than erroring: capacity is a
-- design constant of the caller's cluster, and an overflow would be a programming error whose worst
-- consequence here should be a slightly less informed vote, not a thrown error inside a Heartbeat.
function SurfaceLock.Add(set: SampleSet, position: Vector3, normal: Vector3, instance: BasePart?, distance: number): ()
	local index = set.Count + 1
	local item = set.Items[index]
	if item == nil then
		return
	end
	item.Position = position
	item.Normal = normal
	item.Instance = instance
	item.Distance = distance
	set.Count = index
end

-- Whether two samples lie on one plane, judged by the consensus tolerances.
local function agree(config: ConsensusConfig, a: Sample, b: Sample): boolean
	return ParkourMath.SameSurface(
		a.Position,
		a.Normal,
		b.Position,
		b.Normal,
		config.AgreeAngleDegrees,
		config.AgreeOffsetStuds
	)
end

-- How many members of the cluster around sample `seedIndex` stand on `instance`. A module-level function
-- rather than a closure inside Vote, which would allocate one per call -- see the ALLOCATION note above.
local function clusterVotesFor(set: SampleSet, seedIndex: number, config: ConsensusConfig, instance: BasePart?): number
	local items = set.Items
	local seed = items[seedIndex]
	local votes = 0
	for k = 1, set.Count do
		local other = items[k]
		if other.Instance == instance and (k == seedIndex or agree(config, seed, other)) then
			votes += 1
		end
	end
	return votes
end

-- Finds the plane the most samples agree on and writes it into `out`: the mean normal of the samples that
-- stand on it, and the contact point of the one nearest their centre (see the medoid note below).
-- Returns `out.Valid`.
--
-- A SAMPLE'S SUPPORT is the number of samples (itself included) that agree with it, and the winner is the
-- sample with the most. Ties go to the EARLIER sample, which is why callers add the centre ray first: when
-- the cluster is split evenly the centre ray's plane stands, which is the old single-ray answer and so the
-- conservative one. Agreement is not transitive (A~B and B~C does not make A~C), so the winner's cluster is
-- exactly the samples that agree with the WINNER, never a chain.
--
-- It must then clear two bars, both from config: at least MinSupport rays (a lone ray is never its own
-- witness), and a strict majority of the rays that hit anything. The second is what makes the vote an
-- OUTVOTING: four rays on the real wall and one on a sliver is 4/5, the sliver loses; the same four rays
-- with one more landing somewhere else entirely is still 4/6; but two rays on each of two planes is
-- 2/4, which is nobody's majority, and is rejected rather than coin-flipped.
function SurfaceLock.Vote(set: SampleSet, out: Consensus, config: ConsensusConfig): boolean
	local count = set.Count
	local items = set.Items
	out.Valid = false
	out.Total = count
	out.Support = 0
	if count == 0 then
		return false
	end

	local bestSeed = 0
	local bestSupport = 0
	for i = 1, count do
		local support = 1
		for j = 1, count do
			if j ~= i and agree(config, items[i], items[j]) then
				support += 1
			end
		end
		-- Strictly greater: an earlier (centre-first) seed keeps a tie.
		if support > bestSupport then
			bestSupport = support
			bestSeed = i
		end
	end

	out.Support = bestSupport
	if bestSupport < config.MinSupport or bestSupport * 2 <= count then
		return false
	end

	local seed = items[bestSeed]
	local positionSum = Vector3.zero
	local normalSum = Vector3.zero
	local members = 0
	for j = 1, count do
		local item = items[j]
		if j == bestSeed or agree(config, seed, item) then
			positionSum += item.Position
			normalSum += item.Normal
			members += 1
		end
	end

	-- THE CONTACT POINT IS A REAL ONE. The cluster's members agree within AgreeOffsetStuds of each other, which
	-- is deliberately loose, so a cluster can be spread over a few tenths of a stud -- and the AVERAGE of a
	-- spread cluster is a point on no surface at all, a ghost plane between a wall and the bump on it. Held
	-- against the lock, that ghost lands inside the "same surface" tolerance of the wall and is merged, and
	-- the next one does the same from there: the lock creeps off the wall one ghost at a time. So the position
	-- (and the distance that goes with it) is the MEDOID: the member nearest the cluster's mean, a point some
	-- ray actually hit. The normal is still the mean -- averaging facings is how a curved or rough face gets a
	-- steady normal, and a mean of nearly parallel unit vectors is still a facing.
	local mean = positionSum / members
	local medoid = seed
	local medoidGap = (seed.Position - mean).Magnitude
	for j = 1, count do
		local item = items[j]
		if j ~= bestSeed and agree(config, seed, item) then
			local gap = (item.Position - mean).Magnitude
			-- Strictly nearer: an earlier member (the centre ray, normally) keeps a tie.
			if gap < medoidGap - 1e-6 then
				medoid = item
				medoidGap = gap
			end
		end
	end

	out.Position = medoid.Position
	out.Normal = ParkourMath.SafeUnit(normalSum, seed.Normal)
	out.Distance = medoid.Distance

	-- The part credited is the one the most members stand on, with the SEED winning a tie (it is the
	-- centre ray's, or the earliest agreeing ray's). A plain count over a handful of entries: no table to
	-- tally into. The seed's own count is taken first so that "strictly more" below means exactly that.
	local labelled: BasePart? = seed.Instance
	local labelledVotes = clusterVotesFor(set, bestSeed, config, labelled)
	for j = 1, count do
		local item = items[j]
		if j ~= bestSeed and agree(config, seed, item) then
			local votes = clusterVotesFor(set, bestSeed, config, item.Instance)
			if votes > labelledVotes then
				labelledVotes = votes
				labelled = item.Instance
			end
		end
	end
	out.Instance = labelled

	out.Valid = true
	return true
end

--
-- The lock
--

function SurfaceLock.Reset(lock: Lock): ()
	lock.Held = false
	lock.Instance = nil
	lock.Verdict = "None"
	lock.SwitchLockedUntil = 0
end

-- Held, and confirmed by a sample recently enough to still be believed.
function SurfaceLock.IsFresh(lock: Lock, now: number, config: Config): boolean
	return lock.Held and (now - lock.ConfirmedAt) <= config.LockExpirySeconds
end

-- Whether a hit lies on the held surface. The cheap fast-path question: a probe that is already holding a
-- wall asks this of its single centre ray and, on yes, needs no validation cluster at all.
function SurfaceLock.Matches(lock: Lock, position: Vector3, normal: Vector3, now: number, config: Config): boolean
	if not SurfaceLock.IsFresh(lock, now, config) then
		return false
	end
	return ParkourMath.SameSurface(
		lock.Position,
		lock.Normal,
		position,
		normal,
		config.SameSurfaceAngleDegrees,
		config.SameSurfaceOffsetStuds
	)
end

-- Distance along a ray from `origin` to the held plane, or `fallback` when the ray does not cross it
-- sensibly. How a probe that HELD against a nearer bump still reports the distance to the wall it is
-- holding.
function SurfaceLock.Distance(lock: Lock, origin: Vector3, direction: Vector3, fallback: number): number
	local distance = ParkourMath.RayPlaneDistance(origin, direction, lock.Position, lock.Normal)
	if distance == nil then
		return fallback
	end
	return distance
end

local function adopt(lock: Lock, candidate: Candidate, normal: Vector3, now: number): ()
	lock.Held = true
	lock.Position = candidate.Position
	lock.Normal = normal
	lock.Instance = candidate.Instance
	lock.HeldSince = now
	lock.ConfirmedAt = now
end

-- Decides what the lock does about this frame's candidate (nil for "nothing found"), updates it, and
-- returns the verdict. `castDirection` is the direction the probe's rays travelled, used only to judge which
-- of two normals meets the cast more squarely. See this file's header for the decision table.
function SurfaceLock.Observe(
	lock: Lock,
	candidate: Candidate?,
	castDirection: Vector3,
	now: number,
	config: Config
): Verdict
	if candidate == nil then
		local wasHeld = lock.Held
		lock.Held = false
		lock.Instance = nil
		lock.Verdict = if wasHeld then "Lost" else "None"
		return lock.Verdict
	end

	local candidateNormal = ParkourMath.SafeUnit(candidate.Normal, lock.Normal)

	if not SurfaceLock.IsFresh(lock, now, config) then
		adopt(lock, candidate, candidateNormal, now)
		lock.SwitchLockedUntil = now + config.SwitchCooldownSeconds
		lock.Verdict = "Acquired"
		return lock.Verdict
	end

	if
		ParkourMath.SameSurface(
			lock.Position,
			lock.Normal,
			candidate.Position,
			candidateNormal,
			config.SameSurfaceAngleDegrees,
			config.SameSurfaceOffsetStuds
		)
	then
		-- One wall, many parts. Clamped like every other probe-interval delta so a long gap between samples
		-- cannot make the blend a snap.
		local alpha = ParkourMath.EaseAlpha(config.NormalBlendRate, math.clamp(now - lock.ConfirmedAt, 0, 0.1))
		lock.Normal = ParkourMath.SafeUnit(lock.Normal:Lerp(candidateNormal, alpha), candidateNormal)
		lock.Position = candidate.Position
		lock.Instance = candidate.Instance
		lock.ConfirmedAt = now
		lock.Verdict = "Merged"
		return lock.Verdict
	end

	-- Positive: the challenger is in FRONT of the held plane (nearer the character, since the normal points
	-- out toward them). Negative: behind it.
	local offset = ParkourMath.PlaneOffset(candidate.Position, lock.Position, lock.Normal)

	if offset <= -config.SwitchDistanceStuds then
		-- The held plane is no longer under the character. There is nothing left to be loyal to, so no
		-- cooldown and no comparison: take what is there.
		adopt(lock, candidate, candidateNormal, now)
		lock.SwitchLockedUntil = now
		lock.Verdict = "Switched"
		return lock.Verdict
	end

	local closer = offset >= config.SwitchDistanceStuds
	local sharp = lock.Normal:Dot(candidateNormal) <= math.cos(math.rad(config.SharpNormalDegrees))
	local squarer = false
	local cast = ParkourMath.SafeUnit(castDirection, Vector3.zero)
	if cast.Magnitude > 0 then
		squarer = (-cast:Dot(candidateNormal)) - (-cast:Dot(lock.Normal)) >= config.SwitchSquarenessMargin
	end

	if (closer or sharp or squarer) and now >= lock.SwitchLockedUntil then
		adopt(lock, candidate, candidateNormal, now)
		lock.SwitchLockedUntil = now + config.SwitchCooldownSeconds
		lock.Verdict = "Switched"
		return lock.Verdict
	end

	-- Noise. The held plane stands; its contact point follows the character along it, by taking the
	-- challenger's position and projecting it back onto the plane. That is the whole of "attach to a plane,
	-- not a part": the bump moved the sample, the plane did not move.
	lock.Position = candidate.Position - lock.Normal * offset
	lock.ConfirmedAt = now
	lock.Verdict = "Held"
	return lock.Verdict
end

return SurfaceLock
