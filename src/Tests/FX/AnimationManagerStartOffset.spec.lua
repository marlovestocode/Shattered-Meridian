--!strict
-- Covers AnimationManager's ClipSpec.StartOffsetSeconds -- how a one-shot that was due a fraction of a frame
-- ago (a buffered swing, AttackInputClient's onBufferFrame) starts that far into its clip, so its strike
-- still lands where the schedule put it. The offset is wall-clock seconds and scales by Speed.
--
-- Same fake-track seam as AnimationManagerReplicatedOneShot.spec: no asset loads in the test place.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local AnimationManager = require(ReplicatedStorage.Shared.Animation.AnimationManager)

local CLIP = "rbxassetid://spec-start-offset"
local LENGTH = 1

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
	model.Name = "StartOffsetRig"
	(model.PrimaryPart :: BasePart).Anchored = true
	model.Parent = Workspace
	table.insert(rigs, model)
	return model
end

-- A manager on a real rig whose only track is `track`, stepped by hand.
local function makeManager(track: FakeTrack): AnimationManager.AnimationManagerInstance
	local manager = AnimationManager.new({
		Name = "StartOffsetSpec",
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

	describe("AnimationManager -- StartOffsetSeconds", function()
		it("starts the clip the offset into it, scaled by speed", function()
			local track = newFakeTrack()
			local manager = makeManager(track)
			manager:Claim("Attack", "Spec", { Clip = CLIP, Looped = false, Speed = 2, StartOffsetSeconds = 0.1 })

			expect(track.IsPlaying).to.equal(true)
			expect(math.abs(track.TimePosition - 0.2) < 1e-6).to.equal(true)
			manager:Destroy()
		end)

		it("never seeks past the end of the clip", function()
			local track = newFakeTrack()
			local manager = makeManager(track)
			manager:Claim("Attack", "Spec", { Clip = CLIP, Looped = false, StartOffsetSeconds = 5 })

			expect(track.TimePosition).to.equal(LENGTH)
			manager:Destroy()
		end)

		it("starts at the top without an offset, or with a nonsense one", function()
			local plain = newFakeTrack()
			local plainManager = makeManager(plain)
			plainManager:Claim("Attack", "Spec", { Clip = CLIP, Looped = false })
			expect(plain.TimePosition).to.equal(0)
			plainManager:Destroy()

			for _, offset in { 0, -1, 0 / 0 } do
				local track = newFakeTrack()
				local manager = makeManager(track)
				manager:Claim("Attack", "Spec", { Clip = CLIP, Looped = false, StartOffsetSeconds = offset })

				expect(track.TimePosition).to.equal(0)
				manager:Destroy()
			end
		end)
	end)
end
