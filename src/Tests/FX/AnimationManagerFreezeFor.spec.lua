--!strict
-- Covers AnimationManager.FreezeFor / ThawFor -- the combat hit-stop's way into tracks a manager owns. A raw
-- AdjustSpeed(0) on a manager's track is undone by Step's stranded-speed repair on the next frame (the attacker's
-- hit-stop was one frame long); a freeze made through the manager must survive Step, and only touch the priorities
-- it is asked for.
--
-- Same fake-track seam as AnimationManagerReplicatedOneShot.spec: no asset loads in the test place.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local AnimationManager = require(ReplicatedStorage.Shared.Animation.AnimationManager)

local CLIP = "rbxassetid://spec-freeze-for"
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
	model.Name = "FreezeForRig"
	(model.PrimaryPart :: BasePart).Anchored = true
	model.Parent = Workspace
	table.insert(rigs, model)
	return model
end

-- A manager on a real rig whose only track is `track`, stepped by hand.
local function makeManager(track: FakeTrack): AnimationManager.AnimationManagerInstance
	local manager = AnimationManager.new({
		Name = "FreezeForSpec",
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

	local ACTION = { [Enum.AnimationPriority.Action] = true }

	describe("AnimationManager.FreezeFor", function()
		it("holds a swing track at zero across a watchdog Step", function()
			local track = newFakeTrack()
			local manager = makeManager(track)
			manager:Claim("Attack", "Spec", { Clip = CLIP, Looped = false, Priority = Enum.AnimationPriority.Action })
			local character = manager.character :: Model

			local handled = AnimationManager.FreezeFor(character, 5, ACTION, nil)
			expect(handled[track :: any]).to.equal(true)
			expect(track.Speed).to.equal(0)

			-- The repair that used to undo a raw freeze on the very next frame.
			manager:Step(1 / 60)
			expect(track.Speed).to.equal(0)
			manager:Destroy()
		end)

		it("leaves a track at another priority alone", function()
			local track = newFakeTrack()
			local manager = makeManager(track)
			manager:Claim(
				"Locomotion",
				"Spec",
				{ Clip = CLIP, Looped = true, Priority = Enum.AnimationPriority.Movement }
			)

			local handled = AnimationManager.FreezeFor(manager.character :: Model, 5, ACTION, nil)
			expect(next(handled)).to.equal(nil)
			expect(track.Speed).to.equal(1)
			manager:Destroy()
		end)

		it("ThawFor gives the speed back at once", function()
			local track = newFakeTrack()
			local manager = makeManager(track)
			manager:Claim(
				"Attack",
				"Spec",
				{ Clip = CLIP, Looped = false, Speed = 1.5, Priority = Enum.AnimationPriority.Action }
			)
			local character = manager.character :: Model

			AnimationManager.FreezeFor(character, 5, ACTION, 1.5)
			expect(track.Speed).to.equal(0)
			AnimationManager.ThawFor(character)
			expect(track.Speed).to.equal(1.5)
			manager:Destroy()
		end)

		it("a freeze over a different character touches nothing", function()
			local track = newFakeTrack()
			local manager = makeManager(track)
			manager:Claim("Attack", "Spec", { Clip = CLIP, Looped = false, Priority = Enum.AnimationPriority.Action })

			local other = makeRig()
			local handled = AnimationManager.FreezeFor(other, 5, ACTION, nil)
			expect(next(handled)).to.equal(nil)
			expect(track.Speed).to.equal(1)
			manager:Destroy()
		end)
	end)
end
