--!strict
-- Covers Shared/Parkour/SurfaceLock.lua -- the module that decides which SURFACE a parkour probe is
-- describing, as a plane that persists across samples. Instance-free in its logic (the "parts" below are
-- bare tables standing in for BasePart labels), so every case is plain arithmetic with no character, no
-- Workspace and no yielding.
--
-- The geometry used throughout, stated once. A wall's face lies in the plane z = 0 with outward normal
-- +Z, and the character stands on the +Z side casting toward -Z. So:
--   * "in front of" the wall (nearer the character) is a POSITIVE z offset;
--   * "behind" it (further away) is a NEGATIVE z offset;
--   * a hit slid along the wall changes x or y and nothing else.
--
-- Weighted toward the situations the mountain bug is made of -- two parts a hair apart trading the
-- player back and forth, a bump alternating with the wall behind it, a sliver outvoted by the face it
-- stands on -- and toward the exact boundaries of each rule, because those boundaries are the tuning.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local SurfaceLock = require(ReplicatedStorage.Shared.Parkour.SurfaceLock)

local CONFIG = ParkourConstants.Surface

local CAST = Vector3.new(0, 0, -1)
local WALL_NORMAL = Vector3.new(0, 0, 1)

local function expectClose(actual: number, expected: number, tolerance: number?): ()
	local allowed = tolerance or 1e-4
	expect(math.abs(actual - expected) <= allowed).to.equal(true)
end

-- A stand-in for a BasePart: all the module does with one is carry it and compare it for identity.
local function newPart(): any
	return {}
end

-- A unit normal tilted `degrees` away from the wall's +Z about the vertical axis.
local function tilted(degrees: number): Vector3
	local radians = math.rad(degrees)
	return Vector3.new(math.sin(radians), 0, math.cos(radians))
end

local function sample(x: number, y: number, z: number, normal: Vector3?, part: any): SurfaceLock.Candidate
	return { Position = Vector3.new(x, y, z), Normal = normal or WALL_NORMAL, Instance = part }
end

local function addTo(set: SurfaceLock.SampleSet, x: number, y: number, z: number, part: any, normal: Vector3?): ()
	SurfaceLock.Add(set, Vector3.new(x, y, z), normal or WALL_NORMAL, part, 3 - z)
end

local function newSet(): SurfaceLock.SampleSet
	return SurfaceLock.NewSampleSet(5)
end

return function()
	describe("SurfaceLock.Vote -- several rays outvote a lone one", function()
		it("accepts five rays that all lie on one plane", function()
			local wall = newPart()
			local set, out = newSet(), SurfaceLock.NewConsensus()
			addTo(set, 0, 0, 0, wall)
			addTo(set, 1, 0, 0, wall)
			addTo(set, -1, 0, 0, wall)
			addTo(set, 0, 1, 0, wall)
			addTo(set, 0, -1, 0, wall)

			expect(SurfaceLock.Vote(set, out, CONFIG.Consensus)).to.equal(true)
			expect(out.Valid).to.equal(true)
			expect(out.Support).to.equal(5)
			expect(out.Total).to.equal(5)
			expect(out.Instance).to.equal(wall)
			expectClose(out.Position.X, 0)
			expectClose(out.Position.Z, 0)
			expectClose(out.Normal.Z, 1)
		end)

		it("outvotes a sliver standing proud of the wall -- even when the sliver is the CENTRE ray", function()
			-- The centre ray goes first, so on a tie it would win. Here it is the one landing on a part
			-- 0.8 studs in front of the face, and the four around it all see the wall.
			local wall, sliver = newPart(), newPart()
			local set, out = newSet(), SurfaceLock.NewConsensus()
			addTo(set, 0, 0, 0.8, sliver)
			addTo(set, 1, 0, 0, wall)
			addTo(set, -1, 0, 0, wall)
			addTo(set, 0, 1, 0, wall)
			addTo(set, 0, -1, 0, wall)

			expect(SurfaceLock.Vote(set, out, CONFIG.Consensus)).to.equal(true)
			expect(out.Support).to.equal(4)
			expect(out.Total).to.equal(5)
			expect(out.Instance).to.equal(wall)
			-- And the sliver does not drag the averaged contact point toward itself.
			expectClose(out.Position.Z, 0)
		end)

		it("reports a contact point some ray actually hit, never the average of a spread cluster", function()
			-- Three rays on a bump 0.4 in front of the face and two on the face: all five agree within the
			-- consensus tolerance (0.45), so they are one cluster -- and the MEAN of it, 0.24 off the face, is
			-- a point on neither. Held against a lock on the face that ghost would pass the 0.3 same-surface
			-- test and be merged, and the lock would creep off the wall.
			local wall, bump = newPart(), newPart()
			local set, out = newSet(), SurfaceLock.NewConsensus()
			addTo(set, 0, 0, 0.4, bump)
			addTo(set, 0, 1, 0.4, bump)
			addTo(set, 0, -1, 0.4, bump)
			addTo(set, 1, 0, 0, wall)
			addTo(set, -1, 0, 0, wall)

			expect(SurfaceLock.Vote(set, out, CONFIG.Consensus)).to.equal(true)
			expect(out.Support).to.equal(5)
			-- One of the two real heights, not 0.24.
			expect(out.Position.Z == 0.4 or out.Position.Z == 0).to.equal(true)
			expect(out.Instance).to.equal(bump)
		end)

		it("does not let a held wall creep onto a bump through its own consensus", function()
			-- The end-to-end form of the case above: a lock on the face, then the same five rays arriving
			-- sample after sample. The bump is proud by less than SwitchDistance, so the face must stand.
			local wall, bump = newPart(), newPart()
			local lock = SurfaceLock.NewLock()
			SurfaceLock.Observe(lock, sample(0, 0, 0, WALL_NORMAL, wall), Vector3.new(0, 0, -1), 0, CONFIG)
			local set, out = newSet(), SurfaceLock.NewConsensus()
			for index = 1, 30 do
				SurfaceLock.Clear(set)
				addTo(set, 0, 0, 0.4, bump)
				addTo(set, 0, 1, 0.4, bump)
				addTo(set, 0, -1, 0.4, bump)
				addTo(set, 1, 0, 0, wall)
				addTo(set, -1, 0, 0, wall)
				expect(SurfaceLock.Vote(set, out, CONFIG.Consensus)).to.equal(true)
				SurfaceLock.Observe(lock, out, Vector3.new(0, 0, -1), index * 0.03, CONFIG)
			end
			expectClose(lock.Position.Z, 0)
			expect(lock.Instance).to.equal(wall)
		end)

		it("outvotes a sliver BURIED behind the face just the same", function()
			local wall, buried = newPart(), newPart()
			local set, out = newSet(), SurfaceLock.NewConsensus()
			addTo(set, 0, 0, -1.1, buried)
			addTo(set, 1, 0, 0, wall)
			addTo(set, -1, 0, 0, wall)
			addTo(set, 0, 1, 0, wall)

			expect(SurfaceLock.Vote(set, out, CONFIG.Consensus)).to.equal(true)
			expect(out.Instance).to.equal(wall)
			expect(out.Support).to.equal(3)
		end)

		it("outvotes a ray that hit the same distance but a differently facing surface", function()
			-- The offset test alone would pass this one: it is ON the wall's plane. The normal test is what
			-- refuses it.
			local wall, other = newPart(), newPart()
			local set, out = newSet(), SurfaceLock.NewConsensus()
			addTo(set, 0, 0, 0, other, tilted(60))
			addTo(set, 1, 0, 0, wall)
			addTo(set, -1, 0, 0, wall)

			expect(SurfaceLock.Vote(set, out, CONFIG.Consensus)).to.equal(true)
			expect(out.Instance).to.equal(wall)
		end)

		it("refuses an even split -- two rays on each of two planes is nobody's majority", function()
			local a, b = newPart(), newPart()
			local set, out = newSet(), SurfaceLock.NewConsensus()
			addTo(set, 0, 0, 0, a)
			addTo(set, 1, 0, 0, a)
			addTo(set, 0, 1, 2, b)
			addTo(set, 1, 1, 2, b)

			expect(SurfaceLock.Vote(set, out, CONFIG.Consensus)).to.equal(false)
			expect(out.Valid).to.equal(false)
			expect(out.Support).to.equal(2)
			expect(out.Total).to.equal(4)
		end)

		it("refuses a lone ray -- a single hit is never its own witness", function()
			local set, out = newSet(), SurfaceLock.NewConsensus()
			addTo(set, 0, 0, 0, newPart())
			expect(SurfaceLock.Vote(set, out, CONFIG.Consensus)).to.equal(false)
			expect(out.Support).to.equal(1)
		end)

		it("refuses three rays on three different planes", function()
			local set, out = newSet(), SurfaceLock.NewConsensus()
			addTo(set, 0, 0, 0, newPart())
			addTo(set, 1, 0, 3, newPart())
			addTo(set, -1, 0, -3, newPart())
			expect(SurfaceLock.Vote(set, out, CONFIG.Consensus)).to.equal(false)
		end)

		it("accepts two rays that agree and nothing else hit", function()
			local wall = newPart()
			local set, out = newSet(), SurfaceLock.NewConsensus()
			addTo(set, 0, 0, 0, wall)
			addTo(set, 0, 1, 0, wall)
			expect(SurfaceLock.Vote(set, out, CONFIG.Consensus)).to.equal(true)
			expect(out.Support).to.equal(2)
		end)

		it("returns invalid for an empty set rather than erroring", function()
			local set, out = newSet(), SurfaceLock.NewConsensus()
			expect(SurfaceLock.Vote(set, out, CONFIG.Consensus)).to.equal(false)
			expect(out.Total).to.equal(0)
		end)

		it("credits the part most of the winning rays stand on", function()
			local first, second = newPart(), newPart()
			local set, out = newSet(), SurfaceLock.NewConsensus()
			addTo(set, 0, 0, 0, first)
			addTo(set, 1, 0, 0, second)
			addTo(set, -1, 0, 0, second)
			addTo(set, 0, 1, 0, second)
			expect(SurfaceLock.Vote(set, out, CONFIG.Consensus)).to.equal(true)
			expect(out.Instance).to.equal(second)
		end)

		it("gives a tie between parts on one plane to the earlier ray -- the centre", function()
			local a, b, c = newPart(), newPart(), newPart()
			local set, out = newSet(), SurfaceLock.NewConsensus()
			addTo(set, 0, 0, 0, a)
			addTo(set, 1, 0, 0, b)
			addTo(set, -1, 0, 0, c)
			expect(SurfaceLock.Vote(set, out, CONFIG.Consensus)).to.equal(true)
			expect(out.Instance).to.equal(a)
		end)

		it("ignores samples added past the set's capacity instead of erroring", function()
			local wall = newPart()
			local set = SurfaceLock.NewSampleSet(2)
			addTo(set, 0, 0, 0, wall)
			addTo(set, 1, 0, 0, wall)
			addTo(set, 2, 0, 0, wall)
			expect(set.Count).to.equal(2)
		end)

		it("can be cleared and reused", function()
			local set, out = newSet(), SurfaceLock.NewConsensus()
			addTo(set, 0, 0, 0, newPart())
			addTo(set, 1, 0, 0, newPart())
			SurfaceLock.Clear(set)
			expect(set.Count).to.equal(0)
			expect(SurfaceLock.Vote(set, out, CONFIG.Consensus)).to.equal(false)
		end)
	end)

	describe("SurfaceLock.Observe -- acquiring and losing", function()
		it("adopts the first candidate it is shown", function()
			local lock, wall = SurfaceLock.NewLock(), newPart()
			local verdict = SurfaceLock.Observe(lock, sample(2, 3, 0, nil, wall), CAST, 1, CONFIG)
			expect(verdict).to.equal("Acquired")
			expect(lock.Held).to.equal(true)
			expect(lock.Instance).to.equal(wall)
			expectClose(lock.Position.X, 2)
		end)

		it("reports None, not Lost, for nothing found when nothing was held", function()
			local lock = SurfaceLock.NewLock()
			expect(SurfaceLock.Observe(lock, nil, CAST, 1, CONFIG)).to.equal("None")
			expect(lock.Held).to.equal(false)
		end)

		it("drops the surface the instant nothing is found -- no grace period", function()
			-- States/WallRunning's corner turn depends on a lost wall being reported lost on the frame it goes.
			local lock = SurfaceLock.NewLock()
			SurfaceLock.Observe(lock, sample(0, 0, 0, nil, newPart()), CAST, 1, CONFIG)
			expect(SurfaceLock.Observe(lock, nil, CAST, 1.01, CONFIG)).to.equal("Lost")
			expect(lock.Held).to.equal(false)
			expect(lock.Instance).to.equal(nil)
		end)

		it("forgets a surface nobody has confirmed for longer than the expiry", function()
			local lock = SurfaceLock.NewLock()
			SurfaceLock.Observe(lock, sample(0, 0, 0, nil, newPart()), CAST, 1, CONFIG)
			local later = 1 + CONFIG.LockExpirySeconds + 0.05
			expect(SurfaceLock.IsFresh(lock, later, CONFIG)).to.equal(false)
			-- A flush face on the same plane, far down the wall, is a NEW acquisition -- not a merge into a
			-- surface that stopped being there.
			expect(SurfaceLock.Observe(lock, sample(40, 0, 0, nil, newPart()), CAST, later, CONFIG)).to.equal(
				"Acquired"
			)
		end)

		it("clears a held surface with Reset", function()
			local lock = SurfaceLock.NewLock()
			SurfaceLock.Observe(lock, sample(0, 0, 0, nil, newPart()), CAST, 1, CONFIG)
			SurfaceLock.Reset(lock)
			expect(lock.Held).to.equal(false)
			expect(SurfaceLock.IsFresh(lock, 1, CONFIG)).to.equal(false)
		end)
	end)

	describe("SurfaceLock.Observe -- the same surface on a different part", function()
		it("merges silently and hands the label to the new part", function()
			local lock, a, b = SurfaceLock.NewLock(), newPart(), newPart()
			SurfaceLock.Observe(lock, sample(0, 0, 0, nil, a), CAST, 1, CONFIG)
			local verdict = SurfaceLock.Observe(lock, sample(1.2, 0, 0.1, tilted(2), b), CAST, 1.033, CONFIG)
			expect(verdict).to.equal("Merged")
			expect(lock.Instance).to.equal(b)
			expect(lock.Held).to.equal(true)
		end)

		it("moves the contact point to the new hit and eases the normal rather than snapping it", function()
			local lock = SurfaceLock.NewLock()
			SurfaceLock.Observe(lock, sample(0, 0, 0, nil, newPart()), CAST, 1, CONFIG)
			SurfaceLock.Observe(lock, sample(1.2, 0, 0.1, tilted(8), newPart()), CAST, 1.033, CONFIG)
			expectClose(lock.Position.X, 1.2)
			-- Between the held normal (0 degrees) and the candidate's (8), strictly: eased, not copied.
			local degrees = math.deg(math.acos(math.clamp(lock.Normal:Dot(WALL_NORMAL), -1, 1)))
			expect(degrees > 0.5).to.equal(true)
			expect(degrees < 8).to.equal(true)
		end)

		it("treats parts exactly at the same-surface tolerance as the same surface", function()
			local lock = SurfaceLock.NewLock()
			SurfaceLock.Observe(lock, sample(0, 0, 0, nil, newPart()), CAST, 1, CONFIG)
			local atEdge = sample(1, 0, CONFIG.SameSurfaceOffsetStuds - 0.01, nil, newPart())
			expect(SurfaceLock.Observe(lock, atEdge, CAST, 1.033, CONFIG)).to.equal("Merged")
		end)

		it("does NOT merge a part just past the same-surface offset", function()
			local lock = SurfaceLock.NewLock()
			SurfaceLock.Observe(lock, sample(0, 0, 0, nil, newPart()), CAST, 1, CONFIG)
			local past = sample(1, 0, CONFIG.SameSurfaceOffsetStuds + 0.05, nil, newPart())
			expect(SurfaceLock.Observe(lock, past, CAST, 1.033, CONFIG)).to.equal("Held")
		end)

		it("does NOT merge a part just past the same-surface angle", function()
			local lock = SurfaceLock.NewLock()
			SurfaceLock.Observe(lock, sample(0, 0, 0, nil, newPart()), CAST, 1, CONFIG)
			local past = sample(1, 0, 0, tilted(CONFIG.SameSurfaceAngleDegrees + 3), newPart())
			expect(SurfaceLock.Observe(lock, past, CAST, 1.033, CONFIG)).to.never.equal("Merged")
		end)
	end)

	describe("SurfaceLock.Observe -- hysteresis", function()
		it("holds against a bump in front of the wall that is under the switch distance", function()
			local lock, wall, bump = SurfaceLock.NewLock(), newPart(), newPart()
			SurfaceLock.Observe(lock, sample(0, 0, 0, nil, wall), CAST, 1, CONFIG)
			local verdict = SurfaceLock.Observe(lock, sample(2, 0, 0.5, tilted(8), bump), CAST, 1.1, CONFIG)
			expect(verdict).to.equal("Held")
			expect(lock.Instance).to.equal(wall)
			-- The held plane is untouched ...
			expectClose(lock.Normal.Z, 1)
			-- ... and its contact point follows the character ALONG the plane: x moved, z did not.
			expectClose(lock.Position.X, 2)
			expectClose(lock.Position.Z, 0)
		end)

		it("takes a challenger that is nearer by the switch distance, once the cooldown has passed", function()
			local lock, wall, near = SurfaceLock.NewLock(), newPart(), newPart()
			SurfaceLock.Observe(lock, sample(0, 0, 0, nil, wall), CAST, 1, CONFIG)
			local later = 1 + CONFIG.SwitchCooldownSeconds + 0.05
			local verdict = SurfaceLock.Observe(
				lock,
				sample(1, 0, CONFIG.SwitchDistanceStuds + 0.05, nil, near),
				CAST,
				later,
				CONFIG
			)
			expect(verdict).to.equal("Switched")
			expect(lock.Instance).to.equal(near)
		end)

		it("holds against the same challenger while the switch cooldown is still running", function()
			local lock = SurfaceLock.NewLock()
			SurfaceLock.Observe(lock, sample(0, 0, 0, nil, newPart()), CAST, 1, CONFIG)
			local tooSoon = 1 + CONFIG.SwitchCooldownSeconds * 0.5
			local verdict = SurfaceLock.Observe(
				lock,
				sample(1, 0, CONFIG.SwitchDistanceStuds + 0.05, nil, newPart()),
				CAST,
				tooSoon,
				CONFIG
			)
			expect(verdict).to.equal("Held")
		end)

		it("holds against a challenger just under the switch distance, past the cooldown", function()
			local lock, wall = SurfaceLock.NewLock(), newPart()
			SurfaceLock.Observe(lock, sample(0, 0, 0, nil, wall), CAST, 1, CONFIG)
			-- Long enough after acquisition that the cooldown is not what is holding it, and still inside
			-- the lock's expiry: only the distance rule is being asked.
			local later = 1 + CONFIG.SwitchCooldownSeconds + 0.05
			local verdict = SurfaceLock.Observe(
				lock,
				sample(1, 0, CONFIG.SwitchDistanceStuds - 0.05, tilted(12), newPart()),
				CAST,
				later,
				CONFIG
			)
			expect(verdict).to.equal("Held")
			expect(lock.Instance).to.equal(wall)
		end)

		it("takes a clearly squarer challenger", function()
			-- The held wall meets the cast at 30 degrees; the challenger is dead square. Past the margin, but
			-- under the sharp-turn angle, so only the squareness rule can be what switches it.
			local lock = SurfaceLock.NewLock()
			SurfaceLock.Observe(lock, sample(0, 0, 0, tilted(30), newPart()), CAST, 1, CONFIG)
			local later = 1 + CONFIG.SwitchCooldownSeconds + 0.05
			expect(SurfaceLock.Observe(lock, sample(1, 0, 0.1, WALL_NORMAL, newPart()), CAST, later, CONFIG)).to.equal(
				"Switched"
			)
		end)

		it("does NOT switch for a squareness improvement under the margin", function()
			local lock = SurfaceLock.NewLock()
			SurfaceLock.Observe(lock, sample(0, 0, 0, tilted(20), newPart()), CAST, 1, CONFIG)
			local later = 1 + CONFIG.SwitchCooldownSeconds + 0.05
			expect(SurfaceLock.Observe(lock, sample(1, 0, 0.1, WALL_NORMAL, newPart()), CAST, later, CONFIG)).to.equal(
				"Held"
			)
		end)

		it("takes a sharply turned surface -- a real corner -- once the cooldown has passed", function()
			local lock = SurfaceLock.NewLock()
			SurfaceLock.Observe(lock, sample(0, 0, 0, nil, newPart()), CAST, 1, CONFIG)
			local later = 1 + CONFIG.SwitchCooldownSeconds + 0.05
			local corner = sample(1, 0, 0.1, tilted(CONFIG.SharpNormalDegrees + 5), newPart())
			expect(SurfaceLock.Observe(lock, corner, CAST, later, CONFIG)).to.equal("Switched")
		end)

		it("switches IMMEDIATELY when the held plane has receded -- no cooldown for a vanished wall", function()
			local lock, recess = SurfaceLock.NewLock(), newPart()
			SurfaceLock.Observe(lock, sample(0, 0, 0, nil, newPart()), CAST, 1, CONFIG)
			-- 0.01s later: well inside the cooldown that would hold a contested switch.
			local receded = sample(1, 0, -(CONFIG.SwitchDistanceStuds + 0.2), nil, recess)
			expect(SurfaceLock.Observe(lock, receded, CAST, 1.01, CONFIG)).to.equal("Switched")
			expect(lock.Instance).to.equal(recess)
		end)
	end)

	describe("SurfaceLock.Observe -- the mountain scenarios", function()
		it("two coincident parts trading the hit every sample never produce a switch", function()
			-- The reported bug in miniature: parts A and B a hair apart (0.12 studs, 2 degrees), the ray
			-- landing on whichever the character's position favours this sample. Sixty samples at 30Hz.
			local lock, a, b = SurfaceLock.NewLock(), newPart(), newPart()
			local switches, held = 0, 0
			local maxDegrees = 0
			for index = 0, 59 do
				local now = 1 + index / 30
				local onB = index % 2 == 1
				local candidate = if onB
					then sample(index * 0.4, 0, 0.12, tilted(2), b)
					else sample(index * 0.4, 0, 0, nil, a)
				local verdict = SurfaceLock.Observe(lock, candidate, CAST, now, CONFIG)
				if verdict == "Switched" then
					switches += 1
				end
				if verdict == "Held" then
					held += 1
				end
				local degrees = math.deg(math.acos(math.clamp(lock.Normal:Dot(WALL_NORMAL), -1, 1)))
				maxDegrees = math.max(maxDegrees, degrees)
			end
			expect(switches).to.equal(0)
			expect(held).to.equal(0)
			-- The wall-run's tangent comes off this normal: it must not have swung by the parts' disagreement.
			expect(maxDegrees < 2).to.equal(true)
			expect(lock.Held).to.equal(true)
		end)

		it("a bump alternating with the wall behind it never takes the lock", function()
			local lock, wall, bump = SurfaceLock.NewLock(), newPart(), newPart()
			local switches = 0
			for index = 0, 59 do
				local now = 1 + index / 30
				local candidate = if index % 2 == 1
					then sample(index * 0.4, 0, 0.55, tilted(9), bump)
					else sample(index * 0.4, 0, 0, nil, wall)
				if SurfaceLock.Observe(lock, candidate, CAST, now, CONFIG) == "Switched" then
					switches += 1
				end
				-- After every sample the reported label is the WALL: a merge relabels to it, and a hold on
				-- the bump leaves it alone.
				expect(lock.Instance).to.equal(wall)
			end
			expect(switches).to.equal(0)
			expectClose(lock.Position.Z, 0)
			expectClose(lock.Normal.Z, 1, 1e-3)
		end)

		it("follows a gently curved wall instead of freezing on the first plane", function()
			-- A convex cylinder of radius 28.6 studs (so two degrees of arc is one stud of wall), sampled every
			-- two degrees round 40 degrees of turn. Each step moves the contact point a stud along the wall
			-- and rotates the normal two degrees -- well inside the same-surface bounds -- so the lock has to
			-- merge its way all the way round rather than hold the first plane until it is 40 degrees wrong.
			local radius = 1 / math.rad(2)
			local function onWall(degrees: number): SurfaceLock.Candidate
				local radians = math.rad(degrees)
				return {
					Position = Vector3.new(radius * math.sin(radians), 0, radius * math.cos(radians) - radius),
					Normal = tilted(degrees),
					Instance = newPart(),
				}
			end
			local lock = SurfaceLock.NewLock()
			SurfaceLock.Observe(lock, onWall(0), CAST, 1, CONFIG)
			local merges = 0
			for index = 1, 20 do
				if SurfaceLock.Observe(lock, onWall(index * 2), CAST, 1 + index / 30, CONFIG) == "Merged" then
					merges += 1
				end
			end
			expect(merges).to.equal(20)
			-- It ended facing nearly the way the wall does: a few degrees of lag at most, not 40 of drift.
			local degrees = math.deg(math.acos(math.clamp(lock.Normal:Dot(tilted(40)), -1, 1)))
			expect(degrees < 3).to.equal(true)
		end)
	end)

	describe("SurfaceLock.Matches / Distance", function()
		it("matches a flush hit on a fresh lock and nothing on a stale or empty one", function()
			local lock = SurfaceLock.NewLock()
			expect(SurfaceLock.Matches(lock, Vector3.new(0, 0, 0), WALL_NORMAL, 1, CONFIG)).to.equal(false)
			SurfaceLock.Observe(lock, sample(0, 0, 0, nil, newPart()), CAST, 1, CONFIG)
			expect(SurfaceLock.Matches(lock, Vector3.new(5, 2, 0.1), WALL_NORMAL, 1.03, CONFIG)).to.equal(true)
			expect(SurfaceLock.Matches(lock, Vector3.new(5, 2, 0.9), WALL_NORMAL, 1.03, CONFIG)).to.equal(false)
			expect(SurfaceLock.Matches(lock, Vector3.new(5, 2, 0), WALL_NORMAL, 9, CONFIG)).to.equal(false)
		end)

		it("reports the distance to the HELD plane, not to the bump the ray hit", function()
			local lock = SurfaceLock.NewLock()
			SurfaceLock.Observe(lock, sample(0, 0, 0, nil, newPart()), CAST, 1, CONFIG)
			-- A ray from 3 studs out in front of the wall, travelling straight at it.
			expectClose(SurfaceLock.Distance(lock, Vector3.new(0, 0, 3), CAST, 99), 3)
		end)

		it("falls back when the ray runs parallel to the held plane", function()
			local lock = SurfaceLock.NewLock()
			SurfaceLock.Observe(lock, sample(0, 0, 0, nil, newPart()), CAST, 1, CONFIG)
			expectClose(SurfaceLock.Distance(lock, Vector3.new(0, 0, 3), Vector3.new(1, 0, 0), 7), 7)
		end)
	end)

	describe("Surface tuning -- the relationships that make the rules coherent", function()
		it("keeps same-surface strictly tighter than the switch distance and the consensus tolerance", function()
			-- A hit must not be both 'the same surface' and 'near enough to be a challenger'.
			expect(CONFIG.SameSurfaceOffsetStuds < CONFIG.SwitchDistanceStuds).to.equal(true)
			expect(CONFIG.SameSurfaceAngleDegrees < CONFIG.SharpNormalDegrees).to.equal(true)
			expect(CONFIG.SameSurfaceOffsetStuds <= CONFIG.Consensus.AgreeOffsetStuds).to.equal(true)
			expect(CONFIG.SameSurfaceAngleDegrees <= CONFIG.Consensus.AgreeAngleDegrees).to.equal(true)
		end)

		it("keeps the switch distance inside the half-stud-to-stud band the design calls for", function()
			expect(CONFIG.SwitchDistanceStuds >= 0.5).to.equal(true)
			expect(CONFIG.SwitchDistanceStuds <= 1).to.equal(true)
		end)

		it("keeps the consensus from ever accepting a lone ray", function()
			expect(CONFIG.Consensus.MinSupport >= 2).to.equal(true)
		end)

		it("keeps a lock alive across several cached probe intervals", function()
			-- Probes run at ~30Hz when cached. A lock that expires inside two intervals would die between
			-- samples and the whole feature would silently reduce to Acquired on every frame.
			expect(CONFIG.LockExpirySeconds > 2 * ParkourConstants.Probe.WallIntervalSeconds).to.equal(true)
			expect(CONFIG.SwitchCooldownSeconds < CONFIG.LockExpirySeconds).to.equal(true)
		end)

		it("funds the validation rays inside the per-frame ceiling without starving the base probes", function()
			local probe = ParkourConstants.Probe
			expect(probe.MaxValidationRaysPerFrame <= probe.MaxRaysPerFrame).to.equal(true)
			-- The base worst case (ground 1 + obstacle 6 + walls 4 + ledge 8) must remain fully funded.
			expect(probe.MaxRaysPerFrame - probe.MaxValidationRaysPerFrame >= 19).to.equal(true)
		end)
	end)
end
