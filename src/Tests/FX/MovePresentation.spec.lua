--!strict
-- The client half of per-move presentation (Client/FX/MovePresentation.lua): THE precedence -- move config
-- > the weapon's SFX folder > FXConstants defaults, field by field, unset falling through and only None
-- silencing -- plus the catalogue store's versioning reactions, and the engine-touching half: every new
-- property write (a spark override, a positional Sound, a template clone) actually made against real
-- Instances, since no lint or type pass checks a Roblox property name.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local FXConstants = require(ReplicatedStorage.Shared.FXConstants)
local MovePresentationTypes = require(ReplicatedStorage.Shared.Combat.MovePresentationTypes)

local FX = StarterPlayer.StarterPlayerScripts.Client.FX
local ImpactSparks = require(FX.ImpactSparks)
local MovePresentation = require(FX.MovePresentation)
local MovePresentationCatalog = require(FX.MovePresentationCatalog)
local SoundManager = require(FX.SoundManager)

local TEST_SOUND_ID = "rbxassetid://9118823101"

return function()
	describe("precedence: move > weapon > default", function()
		it("takes the first layer that says anything, and says which", function()
			local value, layer = MovePresentation.Pick("move", "weapon", "default")
			expect(value).to.equal("move")
			expect(layer).to.equal("Move")
			value, layer = MovePresentation.Pick(nil, "weapon", "default")
			expect(value).to.equal("weapon")
			expect(layer).to.equal("Weapon")
			value, layer = MovePresentation.Pick(nil, nil, "default")
			expect(value).to.equal("default")
			expect(layer).to.equal("Default")
			value, layer = MovePresentation.Pick(nil, nil, nil)
			expect(value).to.equal(nil)
			expect(layer).to.equal(nil)
		end)

		it("picks the sound's layer: the move's id, its None, else the weapon, else the default", function()
			expect(MovePresentation.SoundSource({ SoundId = TEST_SOUND_ID }, true, true)).to.equal("Move")
			expect(MovePresentation.SoundSource({ SoundId = "None" }, true, true)).to.equal("None")
			expect(MovePresentation.SoundSource(nil, true, true)).to.equal("Weapon")
			expect(MovePresentation.SoundSource(nil, false, true)).to.equal("Default")
			expect(MovePresentation.SoundSource(nil, false, false)).to.equal(nil)
		end)

		it("lets a cue that only reshapes the sound fall through to the weapon's own", function()
			-- A move that lowers its clang's pitch still clangs with the defender's sword.
			expect(MovePresentation.SoundSource({ Pitch = 0.8, Volume = 1.2 }, true, true)).to.equal("Weapon")
			expect(MovePresentation.SoundSource({ Pitch = 0.8 }, false, true)).to.equal("Default")
		end)

		it("keeps a default colour when unset, hides on None, parses a set one", function()
			local default = Color3.new(1, 0, 0)
			expect(MovePresentation.Color(nil, default)).to.equal(default)
			expect(MovePresentation.Color("None", default)).to.equal(nil)
			local parsed = MovePresentation.Color("#00FF00", default) :: Color3
			expect(parsed.G).to.equal(1)
			expect(MovePresentation.FlashColor({ FlashColor = "None" }, default)).to.equal(nil)
			expect(MovePresentation.FlashColor(nil, default)).to.equal(default)
		end)

		it("loops only a cue that asks to AND names a sound of its own", function()
			expect(MovePresentation.LoopsToEnd(nil)).to.equal(false)
			expect(MovePresentation.LoopsToEnd({ Loop = "RestOfMove" })).to.equal(false)
			expect(MovePresentation.LoopsToEnd({ Loop = "RestOfMove", SoundId = "None" })).to.equal(false)
			expect(MovePresentation.LoopsToEnd({ SoundId = TEST_SOUND_ID })).to.equal(false)
			expect(MovePresentation.LoopsToEnd({ Loop = "RestOfMove", SoundId = TEST_SOUND_ID })).to.equal(true)
		end)

		it("plays a loop as its own instance, counts it, and removes it when stopped", function()
			local name = "SpecLoopSound"
			SoundManager.Register(name, { SoundId = TEST_SOUND_ID, Volume = 0.5 })
			local before = SoundManager.LoopCount()
			local first = SoundManager.PlayLoop(name) :: SoundManager.LoopHandle
			local second = SoundManager.PlayLoop(name) :: SoundManager.LoopHandle
			-- Two loops of one asset are two instances: stopping one leaves the other.
			expect(SoundManager.LoopCount()).to.equal(before + 2)
			first.Stop(0)
			expect(SoundManager.LoopCount()).to.equal(before + 1)
			-- Stopping is idempotent.
			first.Stop(0)
			expect(SoundManager.LoopCount()).to.equal(before + 1)
			second.Stop(0)
			expect(SoundManager.LoopCount()).to.equal(before)
			expect(SoundManager.PlayLoop("NoSuchSpecSound")).to.equal(nil)
		end)

		it("reads a cue's fades: either edge alone, both, or none", function()
			expect(MovePresentation.Fade(nil)).to.equal(nil)
			expect(MovePresentation.Fade({})).to.equal(nil)
			expect(MovePresentation.Fade({ FadeIn = 0, FadeOut = 0 })).to.equal(nil)
			local inOnly = MovePresentation.Fade({ FadeIn = 0.4 }) :: any
			expect(inOnly.In).to.be.near(0.4, 1e-9)
			expect(inOnly.Out).to.equal(nil)
			local outOnly = MovePresentation.Fade({ FadeOut = 1 }) :: any
			expect(outOnly.In).to.equal(nil)
			expect(outOnly.Out).to.equal(1)
			local both = MovePresentation.Fade({ FadeIn = 0.2, FadeOut = 0.5 }) :: any
			expect(both.In).to.be.near(0.2, 1e-9)
			expect(both.Out).to.be.near(0.5, 1e-9)
		end)

		it("times a fade-out to END where the sound ends, shrinking to a sound shorter than the fade", function()
			-- 3s left, a 1s fade: starts 2s from now and runs 1s.
			local startsIn, duration = SoundManager.FadeOutTiming(3, 1)
			expect(startsIn).to.be.near(2, 1e-9)
			expect(duration).to.be.near(1, 1e-9)
			-- 0.4s left, a 1s fade: starts now and fades over what is left.
			startsIn, duration = SoundManager.FadeOutTiming(0.4, 1)
			expect(startsIn).to.be.near(0, 1e-9)
			expect(duration).to.be.near(0.4, 1e-9)
			-- Nothing asked for, nothing left, or a length not known yet: no fade-out.
			local _
			_, duration = SoundManager.FadeOutTiming(3, 0)
			expect(duration).to.equal(0)
			_, duration = SoundManager.FadeOutTiming(0, 1)
			expect(duration).to.equal(0)
			_, duration = SoundManager.FadeOutTiming(0 / 0, 1)
			expect(duration).to.equal(0)
		end)

		it("reads a cue's SoundDelay as seconds from its moment, 0 when unset or not a number", function()
			expect(MovePresentation.SoundDelay(nil)).to.equal(0)
			expect(MovePresentation.SoundDelay({})).to.equal(0)
			expect(MovePresentation.SoundDelay({ SoundDelay = 0.3 })).to.be.near(0.3, 1e-9)
			-- A lead is a legal value; honouring it is the caller's, who knows its moment ahead.
			expect(MovePresentation.SoundDelay({ SoundDelay = -0.5 })).to.be.near(-0.5, 1e-9)
			expect(MovePresentation.SoundDelay({ SoundDelay = 0 / 0 })).to.equal(0)
		end)

		it("resolves the shake: default, a named override, a scale on either, or None", function()
			local default = FXConstants.CameraShake.HitLight
			expect(MovePresentation.Shake(nil, default)).to.equal(default)
			expect(MovePresentation.Shake({ Shake = "None" }, default)).to.equal(nil)
			expect(MovePresentation.Shake({ Shake = "Parry" }, default)).to.equal(FXConstants.CameraShake.Parry)
			local scaled = MovePresentation.Shake({ ShakeScale = 2 }, default) :: any
			expect(scaled.Amplitude).to.be.near(default.Amplitude * 2, 1e-9)
			expect(scaled.DurationSeconds).to.equal(default.DurationSeconds)
			-- A moment with no default shake stays still unless the cue names one.
			expect(MovePresentation.Shake({ ShakeScale = 2 }, nil)).to.equal(nil)
		end)

		it("resolves the sparks: the default preset, the cue's, None, and the overrides", function()
			expect(MovePresentation.Sparks(nil, "Parried")).to.equal("Parried")
			expect(MovePresentation.Sparks({ Sparks = "None" }, "Parried")).to.equal(nil)
			local preset, overrides = MovePresentation.Sparks({ Sparks = "Trade", SparkCount = 2 }, "Parried")
			expect(preset).to.equal("Trade")
			expect((overrides :: any).CountScale).to.equal(2)
			expect((overrides :: any).Punch).to.equal(nil)
			-- The cue's own punch replaces the preset's.
			local _, punchOverrides = MovePresentation.Sparks({ FovPunch = "None" }, "Parried")
			expect((punchOverrides :: any).Punch).to.equal(false)
			expect(MovePresentation.Punch({ FovPunch = "None" })).to.equal(false)
			expect(MovePresentation.Punch({ FovPunch = "Parried" })).to.equal(FXConstants.ImpactSparks.Punches.Parried)
			expect(MovePresentation.Punch(nil)).to.equal(nil)
		end)

		it("resolves the freeze and the audience", function()
			expect(MovePresentation.HitStopSeconds(nil, 0.09)).to.equal(0.09)
			expect(MovePresentation.HitStopSeconds({ HitStopSeconds = 0 }, 0.09)).to.equal(0)
			expect(MovePresentation.Reaches(nil, false)).to.equal(true)
			expect(MovePresentation.Reaches({ Audience = "Everyone" }, false)).to.equal(true)
			expect(MovePresentation.Reaches({ Audience = "Participants" }, false)).to.equal(false)
			expect(MovePresentation.Reaches({ Audience = "Participants" }, true)).to.equal(true)
		end)

		it("reads a Perfect parry's unset fields from the move's Parried cue first", function()
			local presentation = {
				HitParried = { SoundId = TEST_SOUND_ID, Volume = 0.5 },
				HitPerfectParry = { Volume = 1.5 },
			}
			local cue = MovePresentation.CueFrom(presentation, "HitPerfectParry") :: any
			expect(cue.SoundId).to.equal(TEST_SOUND_ID)
			expect(cue.Volume).to.equal(1.5)
			-- ... and never writes into the Parried cue it read from.
			expect(presentation.HitParried.Volume).to.equal(0.5)
			expect(MovePresentation.CueFrom(nil, "HitPerfectParry")).to.equal(nil)
			expect(MovePresentationTypes.HitMomentFor("Parried", true)).to.equal("HitPerfectParry")
			expect(MovePresentationTypes.HitMomentFor("Blocked", nil)).to.equal("HitBlocked")
		end)
	end)

	describe("the catalogue store", function()
		beforeEach(function()
			MovePresentationCatalog.ResetForTesting()
		end)

		afterEach(function()
			MovePresentationCatalog.ResetForTesting()
		end)

		it("serves the block for a MoveId once a snapshot lands, and lists its assets for preloading", function()
			local block = MovePresentationTypes.Validate({
				HitClean = { SoundId = "123" },
			}) :: MovePresentationTypes.Presentation
			expect(MovePresentationCatalog.Apply({ Kind = "Snapshot", Version = 1, Entries = { m = block } })).to.equal(
				"Applied"
			)
			expect(MovePresentation.CueFor("m", "HitClean")).to.be.ok()
			expect(MovePresentation.CueFor("other", "HitClean")).to.equal(nil)
			local entries = MovePresentationCatalog.GetPreloadEntries()
			expect(#entries).to.equal(1)
			expect(entries[1].AssetId).to.equal("rbxassetid://123")
			expect(entries[1].Label).to.equal("MovePresentation.m.HitClean.SoundId")
		end)

		it("reports a delta it cannot apply as stale", function()
			MovePresentationCatalog.Apply({ Kind = "Snapshot", Version = 1, Entries = {} })
			expect(MovePresentationCatalog.Apply({ Kind = "Delta", Base = 5, Version = 6, Entries = {} })).to.equal(
				"Stale"
			)
			expect(MovePresentationCatalog.Version()).to.equal(1)
		end)
	end)

	describe("against real Instances", function()
		it("reshapes a pooled spark burst without error, and puts the default back", function()
			local position = Vector3.new(0, 500, 0)
			ImpactSparks.Play("Parried", position, {
				Color = Color3.new(0, 1, 0),
				CountScale = 0.5,
				SizeScale = 2,
				Texture = "rbxassetid://1",
				Punch = false,
			})
			ImpactSparks.Play("Blocked", position)
		end)

		it("plays a registered sound from a point in the world", function()
			local name = `PresentationSpecPositional{math.random(1, 1e6)}`
			SoundManager.Register(name, { SoundId = TEST_SOUND_ID, Volume = 0.5, PoolSize = 2 })
			SoundManager.PlayAt(name, Vector3.new(10, 20, 30), 80, 1.1, 0.5)
			local found: Sound? = nil
			for _, attachment in workspace.Terrain:GetChildren() do
				if attachment:IsA("Attachment") and attachment.Name == `SoundAt_{name}1` then
					found = attachment:FindFirstChildOfClass("Sound")
				end
			end
			expect(found).to.be.ok()
			local sound = found :: Sound
			expect(sound.RollOffMaxDistance).to.equal(80)
			expect((sound.Parent :: Attachment).WorldPosition).to.equal(Vector3.new(10, 20, 30))
			expect(sound.Volume).to.be.near(0.25, 1e-4)
		end)

		it("clones, fires and releases an authored template by name", function()
			local folderName = FXConstants.MovePresentation.TemplateFolder
			local existing = ReplicatedStorage:FindFirstChild(folderName)
			local folder: Instance
			if existing then
				folder = existing
			else
				local fresh = Instance.new("Folder")
				fresh.Name = folderName
				fresh.Parent = ReplicatedStorage
				folder = fresh
			end
			local template = Instance.new("Attachment")
			template.Name = `SpecTemplate{math.random(1, 1e6)}`
			template:SetAttribute("LifetimeSeconds", 0.1)
			local emitter = Instance.new("ParticleEmitter")
			emitter.Parent = template
			local beam = Instance.new("Beam")
			beam.Parent = template
			template.Parent = folder

			local before = MovePresentation.ActiveTemplateCount()
			local played = MovePresentation.PlayTemplate(
				{ Template = template.Name },
				CFrame.new(0, 500, 0),
				"spec-move",
				"HitClean"
			)
			expect(played).to.equal(true)
			expect(MovePresentation.ActiveTemplateCount()).to.equal(before + 1)
			-- A name the folder does not hold plays nothing (and warns once).
			expect(
				MovePresentation.PlayTemplate({ Template = "NoSuchTemplate" }, CFrame.new(), "spec-move", "HitClean")
			).to.equal(false)
			task.wait(0.25)
			expect(MovePresentation.ActiveTemplateCount()).to.equal(before)

			template:Destroy()
			if existing == nil then
				folder:Destroy()
			end
		end)
	end)
end
