--!strict
--[[
	ParkourAnimator.lua

	Owns: selecting, playing and interrupting the movement clips that go with each parkour state --
	driven by the state id, its variant (wall-run left vs. right, hop vs. vault), and live speed.

	DRIVEN BY THE STATE MACHINE, NOT PARALLEL TO IT. The design was explicit: "make the animation
	system work together with the movement system rather than having parkour animations operate
	independently. Every parkour action should be able to select an appropriate animation based on the
	movement state, direction, speed, surface, and action being performed." So this module has no
	logic of its own about when anything happens -- ParkourController calls OnStateChanged on every
	transition and SetMotion every frame, and the clip is a pure function of what the state machine
	already decided. There is no second opinion here that could drift out of sync with the first.

	INTERRUPTIBLE BY CONSTRUCTION. At most ONE parkour track is playing at any moment, and a state
	change stops it before starting the next -- so the framework can never leave a player locked in an
	animation ("animations should be interruptible when necessary so the player does not get locked
	into an animation when they need to transition into another movement action or combat"). There is
	no queue, no "wait for this to finish," and no clip whose length gates a transition.

	PRIORITY IS THE COMBAT BOUNDARY. Every clip here loads at Enum.AnimationPriority.Movement, while
	Client/FX/CombatAnimator.lua's swings/blocks/dashes load at Core (see that file's own note on why
	it had to match the default rig's own cycle). Movement sits BELOW Core, so a combat action always
	visually wins over a parkour clip without either module needing to coordinate with the other --
	which is the whole point: a player who attacks mid-slide sees the attack, and the slide continues
	to drive their body underneath it.

	A missing or placeholder animation id degrades to no clip playing, never an error -- the same
	tolerance Constants.Flight/Constants.Intro's own placeholder AnimationIds tables already rely on,
	which is what lets this ship before the real clips exist.

	Does not own: any combat animation (CombatAnimator.lua), the decision to change state
	(StateMachine.lua), or any character binding beyond its own Animator lookup.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnimatorUtil = require(ReplicatedStorage.Shared.AnimatorUtil)
local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local ParkourMath = require(ReplicatedStorage.Shared.Parkour.ParkourMath)
local ParkourTypes = require(ReplicatedStorage.Shared.Parkour.ParkourTypes)
local Logger = require(ReplicatedStorage.Shared.Logger)

type MovementStateId = ParkourTypes.MovementStateId

local logger = Logger.scope("ParkourAnimator")

local ANIMATION = ParkourConstants.Animation
local IDS = ParkourConstants.AnimationIds

local ParkourAnimator = {}

-- Client/Loading/AssetPreloader.lua's boot-time preload pass gets RAW CONTENT-ID STRINGS from this
-- module, not pre-built Animation instances -- deliberately unlike CombatAnimator/FlightAnimator/
-- EmoteAnimator's own GetPreloadInstances(), which hand back the very template instances they
-- already keep.
--
-- Those three build their templates once at module load, so exposing them costs nothing. This module
-- has no template table to expose: getTrack() below builds each Animation lazily on first use, for a
-- documented reason (see its own header -- most lives never touch most of these clips, so a respawn
-- stays cheap). Returning instances here would mean constructing all twenty eagerly and throwing
-- that reasoning away just to satisfy the preloader.
--
-- A raw id string is a first-class manifest entry -- ContentProvider:PreloadAsync takes content ids
-- directly, and AssetPreloader's own dedupe keys a string as itself -- so this warms the exact same
-- CDN fetch without owning an instance. Constants.Intro.AnimationIds is already preloaded this same
-- way for the same "no ongoing pool to be the source of truth for" reason.
--
-- WHY IT MATTERS: without this, every parkour clip cold-loaded on FIRST USE -- i.e. mid-vault,
-- mid-wall-run, mid-ledge-grab. That is the worst possible moment to pay a fetch, and it was the
-- single largest gap in the manifest (twenty slots, eight ids the manifest never otherwise saw).
--
-- Empty-id slots are skipped, the same "" convention every other provider applies. Dedupe is left to
-- AssetPreloader (several slots deliberately share one placeholder id).
function ParkourAnimator.GetPreloadInstances(): { string }
	local ids: { string } = {}
	for _, assetId in pairs(IDS) do
		if assetId ~= "" then
			table.insert(ids, assetId)
		end
	end
	return ids
end

-- BLEND TIMES ARE PER CLIP, and every entry in both maps below states which of the three profiles it
-- uses.
--
-- One global fade pair cannot be right for a set this varied: a wall-jump kick and a fall loop are
-- opposite problems. The kick's readable moment is its first frame, so it must arrive fast and LEAVE
-- slowly (its state is a fifth of a second long, so the clip is always cut off mid-swing -- a long fade
-- out is what lets the swing finish underneath the fall instead of being deleted at the transition).
-- The fall loop is the reverse: nothing about its first frame is urgent, and easing into it is what
-- makes going airborne read as a transition rather than a costume change.
--
-- See ParkourConstants.Animation.BlendProfiles for the numbers and the full reasoning.
local PROFILES = ANIMATION.BlendProfiles

type ClipEntry = {
	Key: string,
	Looped: boolean,
	ScalesWithSpeed: boolean,
	FadeIn: number?,
	FadeOut: number?,
}

-- Which clip key each state uses, and whether that clip loops. States absent from this map play
-- nothing at all -- deliberately, and it is most of the map: Idle, Walking, Sprinting and Jumping are
-- served by Roblox's own default character animations, and layering a second set on top of them would
-- mean re-authoring the entire base locomotion set to fix a problem that does not exist. This module
-- covers only the movement this game adds.
local STATE_CLIPS: { [string]: ClipEntry } = {
	Sliding = {
		Key = "SlideLoop",
		Looped = true,
		ScalesWithSpeed = true,
		FadeIn = PROFILES.Settle.FadeIn,
		FadeOut = PROFILES.Settle.FadeOut,
	},
	Rolling = {
		Key = "Roll",
		Looped = false,
		ScalesWithSpeed = false,
		FadeIn = PROFILES.Snap.FadeIn,
		FadeOut = PROFILES.Snap.FadeOut,
	},
	Mantling = {
		Key = "Mantle",
		Looped = false,
		ScalesWithSpeed = false,
		FadeIn = PROFILES.Snap.FadeIn,
		FadeOut = PROFILES.Snap.FadeOut,
	},
	WallJumping = {
		Key = "WallJump",
		Looped = false,
		ScalesWithSpeed = false,
		FadeIn = PROFILES.Snap.FadeIn,
		FadeOut = PROFILES.Snap.FadeOut,
	},
	Leaping = {
		Key = "Leap",
		Looped = false,
		ScalesWithSpeed = false,
		FadeIn = PROFILES.Snap.FadeIn,
		FadeOut = PROFILES.Snap.FadeOut,
	},
	LedgeHanging = {
		Key = "LedgeHang",
		Looped = true,
		ScalesWithSpeed = false,
		FadeIn = PROFILES.Settle.FadeIn,
		FadeOut = PROFILES.Settle.FadeOut,
	},
	LedgeClimbing = {
		Key = "LedgeClimb",
		Looped = false,
		ScalesWithSpeed = false,
		FadeIn = PROFILES.Snap.FadeIn,
		FadeOut = PROFILES.Ground.FadeOut,
	},
	Falling = {
		Key = "FallLoop",
		Looped = true,
		ScalesWithSpeed = false,
		FadeIn = PROFILES.Settle.FadeIn,
		FadeOut = PROFILES.Settle.FadeOut,
	},
	Landing = {
		Key = "LandSoft",
		Looped = false,
		ScalesWithSpeed = false,
		FadeIn = PROFILES.Ground.FadeIn,
		FadeOut = PROFILES.Ground.FadeOut,
	},
}

-- States whose clip depends on a variant the state itself published (ParkourContext.
-- AnimationVariant). Kept as its own map rather than as extra fields on STATE_CLIPS because these are
-- resolved at a different moment -- the variant is only known at the instant of the transition, where
-- STATE_CLIPS is a static property of the state.
--
-- Each entry carries its OWN Looped/ScalesWithSpeed rather than borrowing them from STATE_CLIPS. A
-- variant-driven state need not appear in STATE_CLIPS at all -- WallRunning and Vaulting do not -- and
-- reading playback flags from an entry that is permanently absent silently yields false for both. That
-- is exactly how a wall-run came to play its clip once and stop: ParkourConstants.Animation's whole
-- speed-scaling band (SpeedScaleReferenceSpeed/Min/MaxPlaybackSpeed, authored with a wall-run as its
-- worked example) described behaviour the resolver could never actually select.
local VARIANT_CLIPS: {
	[string]: {
		Looped: boolean,
		ScalesWithSpeed: boolean,
		FadeIn: number?,
		FadeOut: number?,
		Clips: { [string]: string },
	},
} =
	{
		-- One-shot: a vault takes the time the vault takes, so it must not scale with approach speed --
		-- the clip accompanies a kinematic path and the two would drift apart. See SetMotion's header.
		Vaulting = {
			Looped = false,
			ScalesWithSpeed = false,
			FadeIn = PROFILES.Snap.FadeIn,
			FadeOut = PROFILES.Snap.FadeOut,
			Clips = { Hop = "VaultHop", Vault = "VaultOver" },
		},
		-- Loops for as long as the run lasts, and scales with speed -- a wall-run at 34 should not play at
		-- the same cadence as one at 20, which is the case ParkourConstants.Animation is written about.
		WallRunning = {
			Looped = true,
			ScalesWithSpeed = true,
			FadeIn = PROFILES.Settle.FadeIn,
			FadeOut = PROFILES.Settle.FadeOut,
			Clips = { Left = "WallRunLeft", Right = "WallRunRight" },
		},
		-- Mirrored the same way wall-runs are, and for the same reason: kicking off a wall on your left and
		-- kicking off a wall on your right are opposite actions, and one shared clip plays half of them
		-- backwards. "Neutral" is a genuine third case rather than a fallback for missing data -- a wall
		-- square in front of or behind the character has no side (ParkourMath.WallSide returns 0 there), and
		-- playing either mirror for it reads as kicking off nothing.
		--
		-- One-shot and non-scaling: a wall-jump is a single beat whose length is the control lock, not a
		-- cadence that should track speed.
		WallJumping = {
			Looped = false,
			ScalesWithSpeed = false,
			FadeIn = PROFILES.Snap.FadeIn,
			FadeOut = PROFILES.Snap.FadeOut,
			Clips = { Left = "WallJumpLeft", Right = "WallJumpRight", Neutral = "WallJump" },
		},
		-- Also present in STATE_CLIPS (as the no-variant fallback); both agree on one-shot, non-scaling.
		Landing = {
			Looped = false,
			ScalesWithSpeed = false,
			FadeIn = PROFILES.Ground.FadeIn,
			FadeOut = PROFILES.Ground.FadeOut,
			Clips = { Soft = "LandSoft", Medium = "LandSoft", Hard = "LandHard" },
		},
	}

local animator: Animator? = nil
local tracks: { [string]: AnimationTrack } = {}
local activeTrack: AnimationTrack? = nil
local activeKey: string? = nil
-- The OUTGOING clip's own fade-out, remembered so stopActive can honor it. It has to be a property of
-- the clip being stopped rather than of the one starting -- a wall-jump leaves slowly whatever replaces
-- it -- and by the time stopActive runs, the entry it came from is out of scope.
local activeFadeOut = ANIMATION.FadeOutSeconds
-- Last speed SetMotion was told about, so a clip that scales with speed can be STARTED at the right
-- cadence instead of playing its first frames at 1x and being corrected a frame later. That correction
-- is small and constant, which is exactly the kind of thing that reads as the animation not being
-- attached to the movement.
local lastPlanarSpeed = 0
-- Declared up here rather than beside SetMotion (its only reader) because protectedTrackCall below
-- has to be able to clear it when it de-activates a failing track.
local currentScalesWithSpeed = false

-- Runs one AnimationTrack operation such that it CANNOT take the movement frame down with it.
--
-- This is load-bearing, not defensive habit. Every entry point in this module is called from inside
-- ParkourController.step, which runs under a single pcall whose failure handler calls
-- ParkourMotor.Release() -- and Release destroys the LinearVelocity rig that a Velocity-driven state
-- is being driven by. So an error thrown by a track operation does not merely lose a clip: it drops
-- the character's motor on the floor, and if the throw repeats every frame the state is never able to
-- drive the body at all.
--
-- Sliding and wall-running are the sharp edges, because they are the only two clips with
-- ScalesWithSpeed = true (Sliding via STATE_CLIPS, WallRunning via VARIANT_CLIPS). SetMotion returns
-- immediately for every other state, so those two are the cases where a track operation runs on EVERY
-- frame of the action rather than once at the transition -- which turns "the animation does not play"
-- into "the slide does not move you," with nothing on screen connecting the two.
--
-- A failing track is dropped from the cache and de-activated rather than retried: whatever is wrong
-- with it will still be wrong next frame, and the module's contract is that a bad asset costs one
-- warning and no clip -- never movement.
local function protectedTrackCall<T...>(key: string, what: string, operation: (T...) -> (), ...: T...): boolean
	local ok, errorMessage = pcall(operation, ...)
	if ok then
		return true
	end
	logger:warn(
		"Parkour animation operation failed -- dropping the clip, movement continues",
		{ key = key, operation = what, errorMessage = tostring(errorMessage) }
	)
	tracks[key] = nil
	if activeKey == key then
		activeTrack = nil
		activeKey = nil
		activeFadeOut = ANIMATION.FadeOutSeconds
		currentScalesWithSpeed = false
	end
	return false
end

-- Loads (and caches) the track for a clip key. Loading lazily rather than preloading the whole set at
-- bind time keeps a respawn cheap -- most lives never touch most of these clips -- and every failure
-- path returns nil so a bad asset id costs one warning rather than breaking movement.
local function getTrack(key: string): AnimationTrack?
	local existing = tracks[key]
	if existing then
		return existing
	end
	local currentAnimator = animator
	if not currentAnimator then
		return nil
	end
	local assetId = IDS[key]
	if not assetId or assetId == "" then
		return nil
	end

	local animation = Instance.new("Animation")
	animation.Name = `Parkour_{key}`
	animation.AnimationId = assetId

	local ok, trackOrError = pcall(function()
		return currentAnimator:LoadAnimation(animation)
	end)
	if not ok then
		logger:warn("Failed to load parkour animation", { key = key, errorMessage = tostring(trackOrError) })
		return nil
	end
	local track = trackOrError :: AnimationTrack
	tracks[key] = track
	-- Setting Priority is itself a property write on a possibly-broken track, so it goes through the
	-- same protection as Play/Stop/AdjustSpeed rather than sitting unguarded between two pcalls.
	if not protectedTrackCall(key, "SetPriority", function()
		track.Priority = ANIMATION.Priority
	end) then
		return nil
	end
	return track
end

local function stopActive(): ()
	local track = activeTrack
	local key = activeKey
	local fadeOut = activeFadeOut
	if track and key then
		protectedTrackCall(key, "Stop", function()
			track:Stop(fadeOut)
		end)
	end
	activeTrack = nil
	activeKey = nil
	activeFadeOut = ANIMATION.FadeOutSeconds
end

-- Resolves which clip key a state should be playing, given its variant. Returns nil for a state with
-- no clip of its own, which is the common case (see STATE_CLIPS' own note).
-- Whether a clip key has a real asset id behind it. An id left blank is how this codebase says "not
-- authored yet" (see ParkourConstants.AnimationIds' own header), and the difference matters here rather
-- than at load time: a variant whose id is blank should fall THROUGH to the state's shared clip, where
-- one exists, instead of resolving to a key that will silently produce no track. That is what makes the
-- directional wall-jump pair safe to ship half-authored -- a missing WallJumpLeft plays the shared
-- WallJump, not nothing.
local function hasAsset(key: string): boolean
	local assetId = IDS[key]
	return assetId ~= nil and assetId ~= ""
end

local function resolveKey(stateId: MovementStateId, variant: string?): (string?, boolean, boolean, number, number)
	local variantEntry = VARIANT_CLIPS[stateId]
	if variantEntry and variant then
		local key = variantEntry.Clips[variant]
		if key and hasAsset(key) then
			return key,
				variantEntry.Looped,
				variantEntry.ScalesWithSpeed,
				variantEntry.FadeIn or ANIMATION.FadeInSeconds,
				variantEntry.FadeOut or ANIMATION.FadeOutSeconds
		end
	end
	local entry = STATE_CLIPS[stateId]
	if entry then
		return entry.Key,
			entry.Looped,
			entry.ScalesWithSpeed,
			entry.FadeIn or ANIMATION.FadeInSeconds,
			entry.FadeOut or ANIMATION.FadeOutSeconds
	end
	-- Either a state with no clip at all (most of them -- see STATE_CLIPS' own note), or a
	-- variant-driven state whose variant is not resolved yet: the transition frame can legitimately
	-- reach here before the state's Enter has published one, and playing an arbitrary variant would be
	-- worse than playing nothing for one frame.
	return nil, false, false, ANIMATION.FadeInSeconds, ANIMATION.FadeOutSeconds
end

-- Called on every state transition. Stops whatever was playing and starts whatever the new state
-- wants, or nothing.
function ParkourAnimator.OnStateChanged(_previous: MovementStateId, next: MovementStateId, variant: string?): ()
	local key, looped, scalesWithSpeed, fadeIn, fadeOut = resolveKey(next, variant)
	if key == activeKey then
		return
	end
	-- Stopped BEFORE the new one plays, which is what makes this a crossfade rather than a cut:
	-- AnimationTrack:Stop with a fade keeps the outgoing clip playing at falling weight, so for the
	-- length of the two fades both clips are live and the character blends between them. The outgoing
	-- clip's OWN fade-out governs (activeFadeOut, captured when it started) -- a wall-jump leaves slowly
	-- whatever replaces it, and a fall loop leaves at its own pace whatever it hands to.
	stopActive()
	currentScalesWithSpeed = scalesWithSpeed
	if not key then
		return
	end
	local track = getTrack(key)
	if not track then
		return
	end
	-- Activated BEFORE the play attempt so protectedTrackCall can find and clear it if the play throws
	-- -- otherwise a failed clip would be left marked active and SetMotion would keep poking it every
	-- frame, which is precisely the per-frame failure this protection exists to stop.
	activeTrack = track
	activeKey = key
	activeFadeOut = fadeOut
	-- Started AT the right playback speed rather than at 1x and corrected on the next frame. The
	-- correction was a visible hitch at the start of every slide and wall-run: the clip's opening frames
	-- played at the wrong cadence and then jumped, which reads as the animation being bolted on rather
	-- than driven by the movement.
	local playbackSpeed = if scalesWithSpeed
		then ParkourMath.PlaybackSpeed(
			lastPlanarSpeed,
			ANIMATION.SpeedScaleReferenceSpeed,
			ANIMATION.MinPlaybackSpeed,
			ANIMATION.MaxPlaybackSpeed
		)
		else 1
	protectedTrackCall(key, "Play", function()
		track.Looped = looped
		track:Play(fadeIn, 1, playbackSpeed)
	end)
end

-- Per-frame speed feed, so a looping movement clip plays at a cadence that matches how fast the
-- character is actually going. A no-op for clips that don't scale, which is most of them -- a vault
-- should take the time the vault takes regardless of approach speed, or the traversal animation and
-- the kinematic path it accompanies would drift apart.
function ParkourAnimator.SetMotion(planarSpeed: number): ()
	-- Recorded unconditionally, before the early-out: the NEXT clip to start may be one that scales, and
	-- it needs a speed to start at. Recording this only for clips that already scale would mean every
	-- such clip began from a stale value or from nothing.
	lastPlanarSpeed = planarSpeed
	if not currentScalesWithSpeed then
		return
	end
	local track = activeTrack
	local key = activeKey
	if not track or not key then
		return
	end
	local speed = ParkourMath.PlaybackSpeed(
		planarSpeed,
		ANIMATION.SpeedScaleReferenceSpeed,
		ANIMATION.MinPlaybackSpeed,
		ANIMATION.MaxPlaybackSpeed
	)
	-- The one track operation that runs EVERY frame rather than once per transition, and therefore the
	-- one where an unprotected throw stops being a lost animation and becomes lost movement. See
	-- protectedTrackCall's own header.
	protectedTrackCall(key, "AdjustSpeed", function()
		track:AdjustSpeed(speed)
	end)
end

-- Rebuilds against a fresh character's Animator. Tracks from the previous life die with that
-- character's Animator, so the cache is dropped wholesale rather than reused.
function ParkourAnimator.BindCharacter(character: Model): ()
	stopActive()
	tracks = {}
	currentScalesWithSpeed = false
	animator = AnimatorUtil.GetOrCreateAnimator(character)
	if not animator then
		logger:warn("BindCharacter: no Humanoid/Animator available", { character = character.Name })
	end
end

-- Hard stop, for character teardown or the framework being switched off. Distinct from
-- OnStateChanged(x, "Idle") because there may be no state to change to -- the character may already
-- be gone.
function ParkourAnimator.Reset(): ()
	stopActive()
	currentScalesWithSpeed = false
end

function ParkourAnimator.Unbind(): ()
	ParkourAnimator.Reset()
	tracks = {}
	animator = nil
end

return ParkourAnimator
