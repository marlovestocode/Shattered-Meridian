--!strict
-- Covers Shared/Attack/AttackWindows.lua -- a swing clip's real length (what every move with a clip
-- is synced to) and the optional marker-driven WindupSeconds override: a generic Hit marker on any
-- attack clip, or the older stage-specific AttackM<n> on an M1 clip.
--
-- Needs no published asset. KeyframeSequences are built in place with Instance.new and fed in through
-- the injectable extractor, the same shape ParryWindows.spec.lua already established for the identical
-- extraction mechanism this module borrows.
--
-- FAIL-SOFT gets as much attention as extraction, because fail-soft (not fail-closed, unlike parry) is
-- the entire point of this module: a missing or bad marker must always resolve to nil, never to an
-- error or a made-up window, so AttackCatalog.Get's own fallback to the hardcoded WindupSeconds is
-- exactly as if this module had never run.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local AttackConstants = require(ReplicatedStorage.Shared.Attack.AttackConstants)
local AttackWindows = require(ReplicatedStorage.Shared.Attack.AttackWindows)
local LiveTuningContract = require(ServerScriptService.Tests.TestHelpers.LiveTuningContract)

-- Builds a sequence carrying `markers` as {name -> time}. One Keyframe per marker, the same shape
-- ParryWindows.spec.lua's makeSequence uses, plus a bare closing keyframe at `length` when given --
-- which is what makes the clip that long, exactly as an exported clip's last keyframe does.
local function makeSequence(markers: { [string]: number }, length: number?): KeyframeSequence
	local sequence = Instance.new("KeyframeSequence")
	for name, time in markers do
		local keyframe = Instance.new("Keyframe")
		keyframe.Time = time
		local marker = Instance.new("KeyframeMarker")
		marker.Name = name
		marker.Parent = keyframe
		keyframe.Parent = sequence
	end
	if length then
		local closing = Instance.new("Keyframe")
		closing.Time = length
		closing.Parent = sequence
	end
	return sequence
end

-- Points the extractor at a fixed set of markers. Cases that care how many times it was called set
-- their own counting extractor instead.
local function serve(markers: { [string]: number }?, length: number?): ()
	AttackWindows.SetExtractor(function(): KeyframeSequence?
		return if markers then makeSequence(markers, length) else nil
	end)
end

return function()
	afterEach(function()
		AttackWindows.Reset()
		-- Restored to something inert so a later spec file cannot inherit this one's extractor.
		AttackWindows.SetExtractor(function()
			return nil
		end)
	end)

	describe("AttackWindows.EstimateStrikeTime", function()
		-- One keyframe at `time` posing the right arm at `degrees` about X, nested the way an exported R6
		-- clip nests it (HumanoidRootPart > Torso > Right Arm).
		local function keyframeAt(sequence: KeyframeSequence, time: number, degrees: number?): ()
			local keyframe = Instance.new("Keyframe")
			keyframe.Time = time
			if degrees then
				local root = Instance.new("Pose")
				root.Name = "HumanoidRootPart"
				root.Parent = keyframe
				local torso = Instance.new("Pose")
				torso.Name = "Torso"
				torso.Parent = root
				local arm = Instance.new("Pose")
				arm.Name = "Right Arm"
				arm.Weight = 1
				arm.CFrame = CFrame.Angles(math.rad(degrees), 0, 0)
				arm.Parent = torso
			end
			keyframe.Parent = sequence
		end

		it("finds the end of the fastest limb movement -- the blow, not the wind-back", function()
			local sequence = Instance.new("KeyframeSequence")
			keyframeAt(sequence, 0, 0)
			keyframeAt(sequence, 0.2, 30) -- a slow wind-back: 30 degrees in 0.2s
			keyframeAt(sequence, 0.3, -60) -- the blow: 90 degrees in 0.1s
			keyframeAt(sequence, 0.6, 0) -- the recovery: 60 degrees in 0.3s
			expect(AttackWindows.EstimateStrikeTime(sequence, 0.6)).to.be.near(0.3, 1e-6)
		end)

		it("finds nothing in a clip too slow to hold a blow", function()
			local sequence = Instance.new("KeyframeSequence")
			keyframeAt(sequence, 0, 0)
			keyframeAt(sequence, 0.5, 10)
			keyframeAt(sequence, 1, 0)
			expect(AttackWindows.EstimateStrikeTime(sequence, 1)).to.equal(nil)
		end)

		it("finds nothing in a clip with no poses at all", function()
			local sequence = Instance.new("KeyframeSequence")
			keyframeAt(sequence, 0)
			keyframeAt(sequence, 0.5)
			expect(AttackWindows.EstimateStrikeTime(sequence, 0.5)).to.equal(nil)
		end)
	end)

	describe("AttackWindows.MarkerNameFor", function()
		it("derives AttackM<stage> for every Basic stage of every weapon", function()
			expect(AttackWindows.MarkerNameFor("default:Primary:Basic:1")).to.equal("AttackM1")
			expect(AttackWindows.MarkerNameFor("default:Primary:Basic:2")).to.equal("AttackM2")
			expect(AttackWindows.MarkerNameFor("default:Secondary:Basic:3")).to.equal("AttackM3")
		end)

		it("returns nil for anything that is not a Basic stage", function()
			expect(AttackWindows.MarkerNameFor("default:Primary:Heavy:1")).to.equal(nil)
			expect(AttackWindows.MarkerNameFor("default:Primary:Finisher")).to.equal(nil)
			expect(AttackWindows.MarkerNameFor("a-custom-move-slug")).to.equal(nil)
			expect(AttackWindows.MarkerNameFor("default:Primary:Basic:")).to.equal(nil)
		end)
	end)

	describe("AttackWindows.ExtractMarkerTime", function()
		it("reads the marker's own keyframe time", function()
			local sequence = makeSequence({ AttackM1 = 0.31, SomeOtherMarker = 0.5 })
			expect(AttackWindows.ExtractMarkerTime(sequence, "AttackM1")).to.be.near(0.31, 1e-6)
		end)

		it("returns nil when the named marker is not present", function()
			local sequence = makeSequence({ AttackM2 = 0.2 })
			expect(AttackWindows.ExtractMarkerTime(sequence, "AttackM1")).to.equal(nil)
		end)

		it("takes the EARLIEST keyframe when a marker name appears twice", function()
			local sequence = Instance.new("KeyframeSequence")
			for _, time in { 0.4, 0.1, 0.7 } do
				local keyframe = Instance.new("Keyframe")
				keyframe.Time = time
				local marker = Instance.new("KeyframeMarker")
				marker.Name = "AttackM1"
				marker.Parent = keyframe
				keyframe.Parent = sequence
			end
			-- An animator who left two copies meant the first one; picking the later one would
			-- silently push the hit later than intended.
			expect(AttackWindows.ExtractMarkerTime(sequence, "AttackM1")).to.be.near(0.1, 1e-6)
		end)

		it("ignores non-marker children", function()
			local sequence = makeSequence({ AttackM1 = 0.1 })
			local pose = Instance.new("Pose")
			pose.Name = "AttackM1"
			pose.Parent = sequence
			-- The real marker is still found despite the same-named Pose sitting alongside it.
			expect(AttackWindows.ExtractMarkerTime(sequence, "AttackM1")).to.be.near(0.1, 1e-6)
		end)
	end)

	describe("AttackWindows -- fail-soft", function()
		it("returns nil for an id that was never prefetched", function()
			expect(AttackWindows.WindupOverride("default:Primary:Basic:1", "rbxassetid://never-fetched")).to.equal(nil)
		end)

		it("returns nil when the clip carries no usable marker", function()
			serve({ SomeOtherMarker = 0.2 })
			AttackWindows.Prefetch("rbxassetid://half")
			expect(AttackWindows.WindupOverride("default:Primary:Basic:1", "rbxassetid://half")).to.equal(nil)
		end)

		it("returns nil for a blank animation id, never yielding or erroring", function()
			expect(AttackWindows.WindupOverride("default:Primary:Basic:1", "")).to.equal(nil)
		end)

		it("never lets a non-Basic move read an M1 stage marker", function()
			serve({ AttackM1 = 0.31 })
			AttackWindows.Prefetch("rbxassetid://shared")
			-- Same clip id, but Heavy never asks for an "AttackM1" marker at all -- MarkerNameFor
			-- refuses before the cache is ever consulted.
			expect(AttackWindows.WindupOverride("default:Primary:Heavy:1", "rbxassetid://shared")).to.equal(nil)
		end)

		it("refuses a negative marker time rather than honouring it", function()
			serve({ AttackM1 = -0.2 })
			AttackWindows.Prefetch("rbxassetid://negative")
			expect(AttackWindows.WindupOverride("default:Primary:Basic:1", "rbxassetid://negative")).to.equal(nil)
		end)
	end)

	describe("AttackWindows -- the override", function()
		it("serves the cached marker time once prefetched", function()
			serve({ AttackM1 = 0.22 })
			AttackWindows.Prefetch("rbxassetid://basic1")
			expect(AttackWindows.WindupOverride("default:Primary:Basic:1", "rbxassetid://basic1")).to.be.near(
				0.22,
				1e-6
			)
		end)

		it("serves each clip only its own markers", function()
			-- Two different clips, each carrying only its own stage's marker -- Basic1's clip must
			-- never answer for Basic2's marker name or vice versa.
			AttackWindows.SetExtractor(function(animationId: string): KeyframeSequence?
				if animationId == "rbxassetid://basic1" then
					return makeSequence({ AttackM1 = 0.31 })
				end
				return makeSequence({ AttackM2 = 0.31 })
			end)
			AttackWindows.Prefetch("rbxassetid://basic1")
			AttackWindows.Prefetch("rbxassetid://basic2")
			expect(AttackWindows.WindupOverride("default:Primary:Basic:1", "rbxassetid://basic1")).to.be.near(
				0.31,
				1e-6
			)
			expect(AttackWindows.WindupOverride("default:Primary:Basic:2", "rbxassetid://basic2")).to.be.near(
				0.31,
				1e-6
			)
			-- Basic1's clip never carried an AttackM2 marker, so asking for stage 2 against it fails.
			expect(AttackWindows.WindupOverride("default:Primary:Basic:2", "rbxassetid://basic1")).to.equal(nil)
		end)

		it("respects AttackConstants.Windows.Enabled as the one kill switch", function()
			serve({ AttackM1 = 0.22 })
			AttackWindows.Prefetch("rbxassetid://basic1")
			LiveTuningContract.withRestore(function()
				AttackConstants.Windows.Enabled = false
				expect(AttackWindows.WindupOverride("default:Primary:Basic:1", "rbxassetid://basic1")).to.equal(nil)
			end, function()
				AttackConstants.Windows.Enabled = true
			end)
			-- Re-enabled: the cached marker still serves without needing a second Prefetch.
			expect(AttackWindows.WindupOverride("default:Primary:Basic:1", "rbxassetid://basic1")).to.be.near(
				0.22,
				1e-6
			)
		end)
	end)

	describe("AttackWindows -- caching", function()
		it("serves a second WindupOverride without re-extracting", function()
			local calls = 0
			AttackWindows.SetExtractor(function(): KeyframeSequence?
				calls += 1
				return makeSequence({ AttackM1 = 0.3 })
			end)
			AttackWindows.Prefetch("rbxassetid://cached")
			AttackWindows.Prefetch("rbxassetid://cached")
			AttackWindows.WindupOverride("default:Primary:Basic:1", "rbxassetid://cached")
			expect(calls).to.equal(1)
		end)

		it("negatively caches a permanent failure instead of retrying forever", function()
			local calls = 0
			AttackWindows.SetExtractor(function(): KeyframeSequence?
				calls += 1
				return nil
			end)
			AttackWindows.Prefetch("rbxassetid://missing")
			local afterFirst = calls
			AttackWindows.Prefetch("rbxassetid://missing")
			-- The retries inside the first Prefetch are expected; a SECOND Prefetch must add none.
			expect(calls).to.equal(afterFirst)
			expect(afterFirst > 1).to.equal(true)
		end)
	end)

	describe("AttackWindows -- the Hit marker", function()
		it("times any attack, not only an M1", function()
			serve({ Hit = 0.42 }, 1.2)
			AttackWindows.Prefetch("rbxassetid://any")
			for _, moveId in
				{
					"default:Primary:Heavy:1",
					"default:Primary:Finisher",
					"default:DashPunch",
					"a-custom-move-slug",
				}
			do
				expect(AttackWindows.WindupOverride(moveId, "rbxassetid://any")).to.be.near(0.42, 1e-6)
			end
		end)

		it("times an M1 whose clip has no AttackM<n> marker", function()
			serve({ Hit = 0.18 }, 0.7)
			AttackWindows.Prefetch("rbxassetid://m1")
			expect(AttackWindows.WindupOverride("default:Primary:Basic:2", "rbxassetid://m1")).to.be.near(0.18, 1e-6)
		end)

		it("loses to an M1 clip's own AttackM<n>, the more specific statement", function()
			serve({ Hit = 0.18, AttackM1 = 0.25 }, 0.7)
			AttackWindows.Prefetch("rbxassetid://both")
			expect(AttackWindows.WindupOverride("default:Primary:Basic:1", "rbxassetid://both")).to.be.near(0.25, 1e-6)
			-- A stage whose own name is absent still falls through to Hit on the same clip.
			expect(AttackWindows.WindupOverride("default:Primary:Basic:2", "rbxassetid://both")).to.be.near(0.18, 1e-6)
		end)

		it("is switched off by AttackConstants.Windows.Enabled like every other marker", function()
			serve({ Hit = 0.42 }, 1.2)
			AttackWindows.Prefetch("rbxassetid://any")
			LiveTuningContract.withRestore(function()
				AttackConstants.Windows.Enabled = false
				expect(AttackWindows.WindupOverride("default:Primary:Heavy:1", "rbxassetid://any")).to.equal(nil)
			end, function()
				AttackConstants.Windows.Enabled = true
			end)
		end)

		it("reads the name from AttackConstants.Windows.HitMarkerName", function()
			serve({ Impact = 0.3 }, 1.0)
			AttackWindows.Prefetch("rbxassetid://renamed")
			expect(AttackWindows.WindupOverride("default:Primary:Heavy:1", "rbxassetid://renamed")).to.equal(nil)
			LiveTuningContract.withRestore(function()
				AttackConstants.Windows.HitMarkerName = "Impact"
				expect(AttackWindows.WindupOverride("default:Primary:Heavy:1", "rbxassetid://renamed")).to.be.near(
					0.3,
					1e-6
				)
			end, function()
				AttackConstants.Windows.HitMarkerName = "Hit"
			end)
		end)

		it("is reported by ValidateAll as the marker timing a Heavy", function()
			serve({ Hit = 0.5 }, 1.4)
			local records = AttackWindows.ValidateAll({
				{ MoveId = "default:Primary:Heavy:1", AnimationId = "rbxassetid://heavy1" },
			})
			expect(records[1].MarkerName).to.equal("Hit")
			expect(records[1].HasMarker).to.equal(true)
		end)
	end)

	describe("AttackWindows.ValidateAll", function()
		it("reads every clip, reports the Basic marker, and skips blank entries", function()
			serve({ AttackM1 = 0.31 }, 0.8)
			local records = AttackWindows.ValidateAll({
				{ MoveId = "default:Primary:Basic:1", AnimationId = "rbxassetid://basic1" },
				{ MoveId = "default:Primary:Heavy:1", AnimationId = "rbxassetid://heavy1" },
				{ MoveId = "default:Secondary:Basic:1", AnimationId = "" },
			})
			expect(#records).to.equal(2)
			expect(records[1].MoveId).to.equal("default:Primary:Basic:1")
			expect(records[1].MarkerName).to.equal("AttackM1")
			expect(records[1].HasMarker).to.equal(true)
			expect(records[1].ClipLength).to.be.near(0.8, 1e-6)
			-- Heavy never gets a marker override, but its length is read all the same -- every move
			-- with a clip is synced to it.
			expect(records[2].MoveId).to.equal("default:Primary:Heavy:1")
			expect(records[2].MarkerName).to.equal(nil)
			expect(records[2].HasMarker).to.equal(false)
			expect(records[2].ClipLength).to.be.near(0.8, 1e-6)
		end)

		it("reports an unreadable clip as unread, without erroring", function()
			serve(nil)
			local records = AttackWindows.ValidateAll({
				{ MoveId = "default:Primary:Basic:1", AnimationId = "rbxassetid://blank" },
			})
			expect(#records).to.equal(1)
			expect(records[1].Read).to.equal(false)
			expect(records[1].HasMarker).to.equal(false)
			expect(records[1].ClipLength).to.equal(nil)
		end)
	end)

	describe("AttackWindows -- clip length", function()
		it("is the LAST keyframe's time, whatever order the keyframes are in", function()
			local sequence = makeSequence({ AttackM1 = 0.31 }, 0.9)
			local early = Instance.new("Keyframe")
			early.Time = 0.4
			early.Parent = sequence
			expect(AttackWindows.ExtractClipLength(sequence)).to.be.near(0.9, 1e-6)
		end)

		it("is nil for a sequence with nothing past zero", function()
			expect(AttackWindows.ExtractClipLength(Instance.new("KeyframeSequence"))).to.equal(nil)
			expect(AttackWindows.ExtractClipLength(makeSequence({}, 0))).to.equal(nil)
		end)

		it("serves the cached length once prefetched, and nil before", function()
			serve({}, 0.75)
			expect(AttackWindows.ClipLength("rbxassetid://clip")).to.equal(nil)
			AttackWindows.Prefetch("rbxassetid://clip")
			expect(AttackWindows.ClipLength("rbxassetid://clip")).to.be.near(0.75, 1e-6)
		end)

		it("reads the length and the marker off ONE fetch", function()
			local calls = 0
			AttackWindows.SetExtractor(function(): KeyframeSequence?
				calls += 1
				return makeSequence({ AttackM1 = 0.2 }, 0.6)
			end)
			AttackWindows.Prefetch("rbxassetid://both")
			expect(AttackWindows.ClipLength("rbxassetid://both")).to.be.near(0.6, 1e-6)
			expect(AttackWindows.WindupOverride("default:Primary:Basic:1", "rbxassetid://both")).to.be.near(0.2, 1e-6)
			expect(calls).to.equal(1)
		end)

		it("respects AttackConstants.Windows.SyncToClipLength as its own kill switch", function()
			serve({}, 0.75)
			AttackWindows.Prefetch("rbxassetid://clip")
			LiveTuningContract.withRestore(function()
				AttackConstants.Windows.SyncToClipLength = false
				expect(AttackWindows.ClipLength("rbxassetid://clip")).to.equal(nil)
			end, function()
				AttackConstants.Windows.SyncToClipLength = true
			end)
			expect(AttackWindows.ClipLength("rbxassetid://clip")).to.be.near(0.75, 1e-6)
		end)

		it("returns nil for a blank id, never yielding or erroring", function()
			expect(AttackWindows.ClipLength("")).to.equal(nil)
		end)
	end)

	describe("AttackWindows.Request", function()
		it("fetches in the background, once, however often it is asked", function()
			local calls = 0
			AttackWindows.SetExtractor(function(): KeyframeSequence?
				calls += 1
				task.wait()
				return makeSequence({}, 0.5)
			end)
			AttackWindows.Request("rbxassetid://lazy")
			AttackWindows.Request("rbxassetid://lazy")
			-- Returned without waiting on the fetch.
			expect(AttackWindows.ClipLength("rbxassetid://lazy")).to.equal(nil)
			-- Prefetch joins the in-flight request rather than starting a second one.
			AttackWindows.Prefetch("rbxassetid://lazy")
			expect(AttackWindows.ClipLength("rbxassetid://lazy")).to.be.near(0.5, 1e-6)
			AttackWindows.Request("rbxassetid://lazy")
			expect(calls).to.equal(1)
		end)

		it("ignores a blank id", function()
			local calls = 0
			AttackWindows.SetExtractor(function(): KeyframeSequence?
				calls += 1
				return nil
			end)
			AttackWindows.Request("")
			expect(calls).to.equal(0)
		end)
	end)
end
