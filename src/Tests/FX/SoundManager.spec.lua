--!strict
-- Covers Client/FX/SoundManager.lua's PlayLooped/StopLooped fade capability -- the newest and riskiest
-- surface on this module, since it introduces a Tween whose Completed handler can race a fresh
-- PlayLooped call (see SoundManager.lua's own PlayLooped/StopLooped comments for the cancellation
-- contract this pins).
--
-- NOT Instance-free, deliberately, for the same reason Tests/Parkour/ParkourMotor.spec.lua gives: this
-- module drives a real Sound instance and a real TweenService tween, so a stubbed double could only
-- ever assert against this file's own arithmetic. Real asset ids are not needed -- Sound:Play()/:Stop()
-- and the IsPlaying/Volume properties respond to intent immediately regardless of whether the id ever
-- resolves, which is exactly what this spec is testing.
--
-- Every test registers its OWN uniquely-named sound: SoundManager's registry is a module-level
-- singleton with no Unregister, so reusing a name across tests would let one test's leftover Tween or
-- Sound state leak into the next.

local StarterPlayer = game:GetService("StarterPlayer")

local SoundManager = require(StarterPlayer.StarterPlayerScripts.Client.FX.SoundManager)

local nameCounter = 0
local function uniqueName(): string
	nameCounter += 1
	return `SoundManagerSpec{nameCounter}`
end

local TEST_SOUND_ID = "rbxassetid://76038309546970"

-- Sound.Volume is a float32 engine property -- 0.6 in comes back as 0.6000000238418579, so every
-- comparison against a registered volume needs a tolerance rather than exact equality.
local function expectCloseVolume(actual: number, expected: number): ()
	expect(math.abs(actual - expected) <= 1e-4).to.equal(true)
end

return function()
	describe("SoundManager.PlayLooped", function()
		it("plays immediately at full volume with no fade argument", function()
			local name = uniqueName()
			SoundManager.Register(name, { SoundId = TEST_SOUND_ID, Volume = 0.6 })

			SoundManager.PlayLooped(name)

			local sound = (SoundManager.GetPreloadInstances() :: any)[1]
			-- GetPreloadInstances returns every registered sound's instance(s); find this one by name
			-- rather than assuming position, since other specs may have registered sounds first.
			for _, instance in SoundManager.GetPreloadInstances() do
				if instance.Name == name then
					sound = instance
				end
			end
			expect((sound :: Sound).IsPlaying).to.equal(true)
			expectCloseVolume((sound :: Sound).Volume, 0.6)
		end)

		it("starts at zero volume and plays immediately when a fade-in is given", function()
			local name = uniqueName()
			SoundManager.Register(name, { SoundId = TEST_SOUND_ID, Volume = 0.6 })

			SoundManager.PlayLooped(name, 0.2)

			local sound: Sound? = nil
			for _, instance in SoundManager.GetPreloadInstances() do
				if instance.Name == name then
					sound = instance :: Sound
				end
			end
			-- IsPlaying is true immediately -- :Play() is called synchronously, before the tween ever
			-- gets a chance to run a frame. Volume is 0 at this exact instant because that is set
			-- directly (not by the tween) as the fade's starting point.
			expect((sound :: Sound).IsPlaying).to.equal(true)
			expect((sound :: Sound).Volume).to.equal(0)
		end)

		it("reaches the registered volume once a fade-in completes", function()
			local name = uniqueName()
			SoundManager.Register(name, { SoundId = TEST_SOUND_ID, Volume = 0.6 })

			SoundManager.PlayLooped(name, 0.1)
			task.wait(0.25)

			local sound: Sound? = nil
			for _, instance in SoundManager.GetPreloadInstances() do
				if instance.Name == name then
					sound = instance :: Sound
				end
			end
			expectCloseVolume((sound :: Sound).Volume, 0.6)
		end)
	end)

	describe("SoundManager.StopLooped", function()
		it("stops immediately with no fade argument", function()
			local name = uniqueName()
			SoundManager.Register(name, { SoundId = TEST_SOUND_ID, Volume = 0.6 })
			SoundManager.PlayLooped(name)

			SoundManager.StopLooped(name)

			local sound: Sound? = nil
			for _, instance in SoundManager.GetPreloadInstances() do
				if instance.Name == name then
					sound = instance :: Sound
				end
			end
			expect((sound :: Sound).IsPlaying).to.equal(false)
		end)

		it("keeps playing immediately after a fade-out is requested -- the Stop is deferred", function()
			local name = uniqueName()
			SoundManager.Register(name, { SoundId = TEST_SOUND_ID, Volume = 0.6 })
			SoundManager.PlayLooped(name)

			SoundManager.StopLooped(name, 0.2)

			local sound: Sound? = nil
			for _, instance in SoundManager.GetPreloadInstances() do
				if instance.Name == name then
					sound = instance :: Sound
				end
			end
			expect((sound :: Sound).IsPlaying).to.equal(true)
		end)

		it("actually stops once a fade-out completes", function()
			local name = uniqueName()
			SoundManager.Register(name, { SoundId = TEST_SOUND_ID, Volume = 0.6 })
			SoundManager.PlayLooped(name)

			SoundManager.StopLooped(name, 0.1)
			task.wait(0.25)

			local sound: Sound? = nil
			for _, instance in SoundManager.GetPreloadInstances() do
				if instance.Name == name then
					sound = instance :: Sound
				end
			end
			expect((sound :: Sound).IsPlaying).to.equal(false)
			-- Restored rather than left at 0, so a later PlayLooped with no fade of its own does not
			-- inherit a silent instance -- see SoundManager.lua's own StopLooped comment.
			expectCloseVolume((sound :: Sound).Volume, 0.6)
		end)

		it("a fresh PlayLooped cancels a pending fade-out, and the stale tween never stops it", function()
			-- THE RACE this whole feature has to get right: StopLooped's Completed handler is deferred,
			-- so a PlayLooped that arrives before it fires must cancel the tween outright -- otherwise
			-- the OLD fade-out finishes moments later and silently stops the loop that was just
			-- restarted, which is exactly the "why did my sound cut out" bug this test exists to catch.
			local name = uniqueName()
			SoundManager.Register(name, { SoundId = TEST_SOUND_ID, Volume = 0.6 })
			SoundManager.PlayLooped(name)

			SoundManager.StopLooped(name, 0.15)
			SoundManager.PlayLooped(name)

			-- Past the original fade-out's own duration -- if the stale tween were not cancelled, its
			-- Completed handler would have fired by now and stopped the loop.
			task.wait(0.3)

			local sound: Sound? = nil
			for _, instance in SoundManager.GetPreloadInstances() do
				if instance.Name == name then
					sound = instance :: Sound
				end
			end
			expect((sound :: Sound).IsPlaying).to.equal(true)
			expectCloseVolume((sound :: Sound).Volume, 0.6)
		end)
	end)
end
