--!strict
-- Covers AnimationManager's ClipSpec.ReplicatedOneShot -- the fix for a server-played one-shot (a grab's
-- throw clips) that kept playing forever on every client. AnimationTrack.Looped does not replicate, and a
-- one-shot that ends by itself on the server sends clients no stop, so the only end that reaches them is
-- an explicit Stop while the track is still playing. These cases pin exactly that: the track is played
-- looped, and the manager itself calls Stop at the end of the first pass.
--
-- A plain table stands in for the AnimationTrack through the manager's LoadTrack seam, so the playhead is
-- set by hand rather than by a loaded asset (none exists in the test place), and Step is driven manually.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local AnimationManager = require(ReplicatedStorage.Shared.Animation.AnimationManager)

local CLIP = "rbxassetid://spec-replicated-one-shot"
local LENGTH = 1
local FADE_OUT = 0.1

type FakeTrack = {
	Looped: boolean,
	Priority: Enum.AnimationPriority,
	IsPlaying: boolean,
	Speed: number,
	Length: number,
	TimePosition: number,
	StopCalls: number,
	Stopped: RBXScriptSignal,
	StoppedEvent: BindableEvent,
	Play: (self: FakeTrack, fadeIn: number?, weight: number?, speed: number?) -> (),
	Stop: (self: FakeTrack, fadeOut: number?) -> (),
	AdjustWeight: (self: FakeTrack, weight: number) -> (),
	AdjustSpeed: (self: FakeTrack, speed: number) -> (),
	Destroy: (self: FakeTrack) -> (),
}

local function newFakeTrack(): FakeTrack
	local stoppedEvent = Instance.new("BindableEvent")
	local track: FakeTrack = {
		Looped = false,
		Priority = Enum.AnimationPriority.Core,
		IsPlaying = false,
		Speed = 1,
		Length = LENGTH,
		TimePosition = 0,
		StopCalls = 0,
		Stopped = stoppedEvent.Event,
		StoppedEvent = stoppedEvent,
		Play = function(self: FakeTrack, _fadeIn: number?, _weight: number?, speed: number?)
			self.IsPlaying = true
			self.Speed = speed or 1
		end,
		Stop = function(self: FakeTrack, _fadeOut: number?)
			self.StopCalls += 1
			self.IsPlaying = false
			self.StoppedEvent:Fire()
		end,
		AdjustWeight = function(_self: FakeTrack, _weight: number) end,
		AdjustSpeed = function(self: FakeTrack, speed: number)
			self.Speed = speed
		end,
		Destroy = function(self: FakeTrack)
			self.StoppedEvent:Destroy()
		end,
	}
	return track
end

local rigs: { Model } = {}

local function makeRig(): Model
	local model =
		Players:CreateHumanoidModelFromDescription(Instance.new("HumanoidDescription"), Enum.HumanoidRigType.R6)
	model.Name = "OneShotRig"
	(model.PrimaryPart :: BasePart).Anchored = true
	model.Parent = Workspace
	table.insert(rigs, model)
	return model
end

-- A manager on a real rig whose only track is `track`, stepped by hand.
local function makeManager(track: FakeTrack): AnimationManager.AnimationManagerInstance
	local manager = AnimationManager.new({
		Name = "ReplicatedOneShotSpec",
		Stepping = "Manual",
		LoadTrack = function(_animator: Animator, _clip: string, _assetId: string): AnimationTrack?
			return track :: any
		end,
	})
	assert(manager:Bind(makeRig()), "the spec rig must bind")
	return manager
end

return function()
	afterEach(function()
		for _, rig in rigs do
			rig:Destroy()
		end
		table.clear(rigs)
	end)

	describe("AnimationManager -- ReplicatedOneShot", function()
		it("plays the track looped, so it agrees with an asset exported looped", function()
			local track = newFakeTrack()
			local manager = makeManager(track)

			manager:Claim("Grab", "Spec", { Clip = CLIP, Looped = false, ReplicatedOneShot = true })

			expect(track.IsPlaying).to.equal(true)
			expect(track.Looped).to.equal(true)
			manager:Destroy()
		end)

		it("stops the track itself, while it is still playing, a fade-out before the end of the pass", function()
			local track = newFakeTrack()
			local manager = makeManager(track)
			local finished: string? = nil
			manager:Claim("Grab", "Spec", {
				Clip = CLIP,
				Looped = false,
				ReplicatedOneShot = true,
				FadeOut = FADE_OUT,
				OnFinished = function(_clip, reason)
					finished = reason
				end,
			})

			track.TimePosition = LENGTH * 0.5
			manager:Step()
			expect(track.StopCalls).to.equal(0)
			expect(finished).to.equal(nil)

			track.TimePosition = LENGTH - FADE_OUT
			manager:Step()
			expect(track.StopCalls).to.equal(1)
			expect(finished).to.equal("Completed")
			expect(manager:GetActiveClip("Grab")).to.equal(nil)
			manager:Destroy()
		end)

		it("still ends the first pass when the playhead wrapped between two steps", function()
			local track = newFakeTrack()
			local manager = makeManager(track)
			local finished: string? = nil
			manager:Claim("Grab", "Spec", {
				Clip = CLIP,
				Looped = false,
				ReplicatedOneShot = true,
				FadeOut = FADE_OUT,
				OnFinished = function(_clip, reason)
					finished = reason
				end,
			})

			track.TimePosition = LENGTH * 0.6
			manager:Step()
			track.TimePosition = LENGTH * 0.05
			manager:Step()

			expect(track.StopCalls).to.equal(1)
			expect(finished).to.equal("Completed")
			manager:Destroy()
		end)

		it("does not replay once finished when the same source clears afterwards", function()
			local track = newFakeTrack()
			local manager = makeManager(track)
			manager:Claim("Grab", "Spec", { Clip = CLIP, Looped = false, ReplicatedOneShot = true })
			track.TimePosition = LENGTH
			manager:Step()

			manager:Clear("Grab", "Spec")

			expect(track.IsPlaying).to.equal(false)
			expect(manager:GetActiveClip("Grab")).to.equal(nil)
			manager:Destroy()
		end)

		it("leaves an ordinary one-shot to end by itself", function()
			local track = newFakeTrack()
			local manager = makeManager(track)
			manager:Claim("Grab", "Spec", { Clip = CLIP, Looped = false })

			track.TimePosition = LENGTH - FADE_OUT
			manager:Step()

			expect(track.Looped).to.equal(false)
			expect(track.StopCalls).to.equal(0)
			manager:Destroy()
		end)
	end)
end
