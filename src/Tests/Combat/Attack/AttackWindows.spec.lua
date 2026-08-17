--!strict
-- Covers Shared/Attack/AttackWindows.lua -- the optional marker-driven WindupSeconds override for a
-- Basic-string (M1) swing.
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
-- ParryWindows.spec.lua's makeSequence uses.
local function makeSequence(markers: { [string]: number }): KeyframeSequence
	local sequence = Instance.new("KeyframeSequence")
	for name, time in markers do
		local keyframe = Instance.new("Keyframe")
		keyframe.Time = time
		local marker = Instance.new("KeyframeMarker")
		marker.Name = name
		marker.Parent = keyframe
		keyframe.Parent = sequence
	end
	return sequence
end

-- Points the extractor at a fixed set of markers. Cases that care how many times it was called set
-- their own counting extractor instead.
local function serve(markers: { [string]: number }?): ()
	AttackWindows.SetExtractor(function(): KeyframeSequence?
		return if markers then makeSequence(markers) else nil
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
			AttackWindows.Prefetch("rbxassetid://half", "AttackM1")
			expect(AttackWindows.WindupOverride("default:Primary:Basic:1", "rbxassetid://half")).to.equal(nil)
		end)

		it("returns nil for a blank animation id, never yielding or erroring", function()
			expect(AttackWindows.WindupOverride("default:Primary:Basic:1", "")).to.equal(nil)
		end)

		it("returns nil for a move that is not a Basic stage even with a cached marker", function()
			serve({ AttackM1 = 0.31 })
			AttackWindows.Prefetch("rbxassetid://shared", "AttackM1")
			-- Same clip id, but Heavy never asks for an "AttackM1" marker at all -- MarkerNameFor
			-- refuses before the cache is ever consulted.
			expect(AttackWindows.WindupOverride("default:Primary:Heavy:1", "rbxassetid://shared")).to.equal(nil)
		end)

		it("refuses a negative marker time rather than honouring it", function()
			serve({ AttackM1 = -0.2 })
			local hasMarker = AttackWindows.Prefetch("rbxassetid://negative", "AttackM1")
			expect(hasMarker).to.equal(false)
			expect(AttackWindows.WindupOverride("default:Primary:Basic:1", "rbxassetid://negative")).to.equal(nil)
		end)
	end)

	describe("AttackWindows -- the override", function()
		it("serves the cached marker time once prefetched", function()
			serve({ AttackM1 = 0.22 })
			AttackWindows.Prefetch("rbxassetid://basic1", "AttackM1")
			expect(AttackWindows.WindupOverride("default:Primary:Basic:1", "rbxassetid://basic1")).to.be.near(
				0.22,
				1e-6
			)
		end)

		it("keys the cache by BOTH the animation id and the marker name", function()
			-- Two different clips, each carrying only its own stage's marker -- Basic1's clip must
			-- never answer for Basic2's marker name or vice versa.
			AttackWindows.SetExtractor(function(animationId: string): KeyframeSequence?
				if animationId == "rbxassetid://basic1" then
					return makeSequence({ AttackM1 = 0.31 })
				end
				return makeSequence({ AttackM2 = 0.31 })
			end)
			AttackWindows.Prefetch("rbxassetid://basic1", "AttackM1")
			AttackWindows.Prefetch("rbxassetid://basic2", "AttackM2")
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
			AttackWindows.Prefetch("rbxassetid://basic1", "AttackM1")
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
			AttackWindows.Prefetch("rbxassetid://cached", "AttackM1")
			AttackWindows.Prefetch("rbxassetid://cached", "AttackM1")
			AttackWindows.WindupOverride("default:Primary:Basic:1", "rbxassetid://cached")
			expect(calls).to.equal(1)
		end)

		it("negatively caches a permanent failure instead of retrying forever", function()
			local calls = 0
			AttackWindows.SetExtractor(function(): KeyframeSequence?
				calls += 1
				return nil
			end)
			AttackWindows.Prefetch("rbxassetid://missing", "AttackM1")
			local afterFirst = calls
			AttackWindows.Prefetch("rbxassetid://missing", "AttackM1")
			-- The retries inside the first Prefetch are expected; a SECOND Prefetch must add none.
			expect(calls).to.equal(afterFirst)
			expect(afterFirst > 1).to.equal(true)
		end)
	end)

	describe("AttackWindows.ValidateAll", function()
		it("reports a marker-driven entry and skips non-Basic/blank entries", function()
			serve({ AttackM1 = 0.31 })
			local records = AttackWindows.ValidateAll({
				{ MoveId = "default:Primary:Basic:1", AnimationId = "rbxassetid://basic1" },
				{ MoveId = "default:Primary:Heavy:1", AnimationId = "rbxassetid://heavy1" },
				{ MoveId = "default:Secondary:Basic:1", AnimationId = "" },
			})
			expect(#records).to.equal(1)
			expect(records[1].MoveId).to.equal("default:Primary:Basic:1")
			expect(records[1].MarkerName).to.equal("AttackM1")
			expect(records[1].HasMarker).to.equal(true)
		end)

		it("reports HasMarker=false for a Basic clip with no usable marker, without erroring", function()
			serve(nil)
			local records = AttackWindows.ValidateAll({
				{ MoveId = "default:Primary:Basic:1", AnimationId = "rbxassetid://blank" },
			})
			expect(#records).to.equal(1)
			expect(records[1].HasMarker).to.equal(false)
		end)
	end)
end
