--!strict
--[[
	ClipScrubber.lua

	Owns: the Move Editor's clip scrub and asset previews on THIS client -- your own character held at one
	instant of the open move's clip, a clip played through once, a sound id played once. Nothing here reaches
	the server or decides anything; it is a way of looking.

	THE SCRUB IS SWING TIME. The readout's timeline (Screens/DevTools/MoveEditor/TimelineBar.lua) is drawn in
	the effective swing's seconds, and the screen writes MoveEditorHandle.ScrubTime in the same unit. The clip
	is played at the effective PlaybackSpeed (weapon speed x tempo, or a borrowed clip's retime), so the clip
	instant for a swing time is `time * PlaybackSpeed` -- the same mapping AttackCatalog uses, which is why a
	strike marker on the bar lands on the frame the clip strikes in. The clip is the EFFECTIVE one
	(MoveEditorTypes.EffectiveTiming.AnimationId): the move's own, or the weapon's for a Default move.

	HELD, NOT PLAYED. A scrub plays the track at speed 0 and sets its TimePosition, so the pose is exactly that
	instant and stays there until the next scrub or Release. Because the pose is on your real character, the
	in-world hitbox preview (HitboxWorldPreview), which rides the character's parts, follows it: a hand- or
	weapon-anchored volume is drawn where it really is at that moment. Playing advances ScrubTime itself, at
	real speed, looping over the swing, so the readout's playhead and the pose never disagree.

	A new selection, a clip change and closing the editor all release the character.

	Lives under DevTools (omitted from live.project.json with the editor).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")

local Fusion = require(ReplicatedStorage.Packages.Fusion)
local AnimatorUtil = require(ReplicatedStorage.Shared.AnimatorUtil)
local Logger = require(ReplicatedStorage.Shared.Logger)
local WeaponAssets = require(ReplicatedStorage.Shared.Combat.WeaponAssets)

local peek = Fusion.peek

local logger = Logger.scope("ClipScrubber")

local ClipScrubber = {}

-- Above the idle/run/attack tracks, so the held pose is the one shown.
local PRIORITY = Enum.AnimationPriority.Action4
-- How long a preview sound may live before it is cleaned up whatever it is doing.
local SOUND_LIFETIME_SECONDS = 15

type Handle = any

type Clip = {
	Id: string,
	Speed: number,
	-- The swing the scrub loops over, in swing seconds.
	Span: number,
}

local function clipOf(handle: Handle): Clip?
	local entry = peek(handle.SelectedEntry)
	local effective = entry and entry.Effective
	if not effective or effective.AnimationId == "" then
		return nil
	end
	local swing = effective.WindupSeconds + effective.ActiveSeconds + effective.RecoverySeconds
	return {
		Id = WeaponAssets.NormalizeAssetId(effective.AnimationId),
		Speed = if effective.PlaybackSpeed > 0 then effective.PlaybackSpeed else 1,
		Span = math.max(effective.ClipSeconds or 0, swing, 1e-2),
	}
end

local function animatorOfLocal(): Animator?
	local character = Players.LocalPlayer.Character
	return if character then AnimatorUtil.GetOrCreateAnimator(character) else nil
end

-- Binds the scrub to the handle. Returns the status lines the driver shows for the two previews.
function ClipScrubber.Start(handle: Handle): {
	PreviewAnimation: (id: string) -> string,
	PreviewSound: (id: string) -> string,
}
	local scope = Fusion.scoped(Fusion)
	local held: AnimationTrack? = nil
	local heldId = ""
	local once: AnimationTrack? = nil

	local function release(): ()
		if held then
			held:Stop(0)
			held:Destroy()
		end
		held = nil
		heldId = ""
	end

	local function load(id: string): AnimationTrack?
		local animator = animatorOfLocal()
		if not animator then
			return nil
		end
		local animation = Instance.new("Animation")
		animation.AnimationId = id
		local ok, track = pcall(function()
			return animator:LoadAnimation(animation)
		end)
		animation:Destroy()
		if not ok or not track then
			logger:warn("could not load the clip", { id = id, error = track })
			return nil
		end
		track.Priority = PRIORITY
		track.Looped = false
		return track
	end

	local function holdAt(time: number): ()
		local clip = clipOf(handle)
		if not clip then
			release()
			return
		end
		if held == nil or heldId ~= clip.Id then
			release()
			held = load(clip.Id)
			heldId = clip.Id
			if held then
				held:Play(0, 1, 0)
			end
		end
		local track = held
		if not track then
			return
		end
		track:AdjustSpeed(0)
		local length = if track.Length > 0 then track.Length else math.huge
		track.TimePosition = math.clamp(time * clip.Speed, 0, math.max(length - 1e-3, 0))
	end

	scope:Observer(handle.ScrubTime):onChange(function()
		local time = peek(handle.ScrubTime)
		if time == nil then
			release()
		else
			holdAt(time)
		end
	end)

	-- Anything that changes which clip or which move is under the scrub lets the character go.
	local function reset(): ()
		handle.ScrubPlaying:set(false)
		handle.ScrubTime:set(nil)
		release()
	end
	scope:Observer(handle.SelectedId):onChange(reset)
	scope:Observer(handle.IsOpen):onChange(function()
		if not peek(handle.IsOpen) then
			reset()
		end
	end)
	scope:Observer(handle.SelectedEntry):onChange(function()
		local clip = clipOf(handle)
		if heldId ~= "" and (clip == nil or clip.Id ~= heldId) then
			reset()
		end
	end)

	table.insert(
		scope,
		RunService.Heartbeat:Connect(function(dt: number)
			if not peek(handle.ScrubPlaying) then
				return
			end
			local clip = clipOf(handle)
			if not clip then
				handle.ScrubPlaying:set(false)
				return
			end
			local time = (peek(handle.ScrubTime) or 0) + dt
			handle.ScrubTime:set(if time > clip.Span then 0 else time)
		end)
	)

	local function previewAnimation(id: string): string
		local normalized = WeaponAssets.NormalizeAssetId(id)
		if normalized == "" then
			return "Play: there is no animation id to play."
		end
		reset()
		if once then
			once:Stop(0)
			once:Destroy()
		end
		local track = load(normalized)
		once = track
		if not track then
			return "Play: that clip did not load -- check the id, and that the game may use it."
		end
		track:Play(0.05)
		return "Playing the clip once on your character."
	end

	local function previewSound(id: string): string
		local trimmed = string.match(id, "^%s*(.-)%s*$") or ""
		if trimmed == "" or string.lower(trimmed) == "none" then
			return "Play: blank plays the moment's default sound, and None plays nothing -- Preview the moment to hear either."
		end
		local normalized = WeaponAssets.NormalizeAssetId(trimmed)
		local sound = Instance.new("Sound")
		sound.Name = "MoveEditorPreview"
		sound.SoundId = normalized
		sound.Parent = SoundService
		local ok, problem = pcall(function()
			SoundService:PlayLocalSound(sound)
		end)
		task.delay(SOUND_LIFETIME_SECONDS, function()
			sound:Destroy()
		end)
		if not ok then
			logger:warn("could not play the sound", { id = normalized, error = problem })
			return "Play: that sound did not play -- check the id."
		end
		return "Playing the sound, for you only."
	end

	return {
		PreviewAnimation = previewAnimation,
		PreviewSound = previewSound,
	}
end

return ClipScrubber
