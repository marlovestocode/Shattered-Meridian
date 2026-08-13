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

-- Which clip key each state uses, and whether that clip loops. States absent from this map play
-- nothing at all -- deliberately, and it is most of the map: Idle, Walking, Sprinting and Jumping are
-- served by Roblox's own default character animations, and layering a second set on top of them would
-- mean re-authoring the entire base locomotion set to fix a problem that does not exist. This module
-- covers only the movement this game adds.
local STATE_CLIPS: { [string]: { Key: string, Looped: boolean, ScalesWithSpeed: boolean } } = {
	Sliding = { Key = "SlideLoop", Looped = true, ScalesWithSpeed = true },
	Rolling = { Key = "Roll", Looped = false, ScalesWithSpeed = false },
	Mantling = { Key = "Mantle", Looped = false, ScalesWithSpeed = false },
	WallJumping = { Key = "WallJump", Looped = false, ScalesWithSpeed = false },
	LedgeHanging = { Key = "LedgeHang", Looped = true, ScalesWithSpeed = false },
	LedgeClimbing = { Key = "LedgeClimb", Looped = false, ScalesWithSpeed = false },
	Falling = { Key = "FallLoop", Looped = true, ScalesWithSpeed = false },
	Landing = { Key = "LandSoft", Looped = false, ScalesWithSpeed = false },
}

-- States whose clip depends on a variant the state itself published (ParkourContext.
-- AnimationVariant). Kept as its own map rather than as extra fields on STATE_CLIPS because these are
-- resolved at a different moment -- the variant is only known at the instant of the transition, where
-- STATE_CLIPS is a static property of the state.
local VARIANT_CLIPS: { [string]: { [string]: string } } = {
	Vaulting = { Hop = "VaultHop", Vault = "VaultOver" },
	WallRunning = { Left = "WallRunLeft", Right = "WallRunRight" },
	Landing = { Soft = "LandSoft", Medium = "LandSoft", Hard = "LandHard" },
}

local animator: Animator? = nil
local tracks: { [string]: AnimationTrack } = {}
local activeTrack: AnimationTrack? = nil
local activeKey: string? = nil
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
-- Sliding is the sharp edge, because it is the ONLY entry in STATE_CLIPS with ScalesWithSpeed = true.
-- SetMotion returns immediately for every other state, so a bad slide clip is the one case where a
-- track operation runs on EVERY frame of the action rather than once at the transition -- which turns
-- "the animation does not play" into "the slide does not move you," with nothing on screen connecting
-- the two.
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
	if track and key then
		protectedTrackCall(key, "Stop", function()
			track:Stop(ANIMATION.FadeOutSeconds)
		end)
	end
	activeTrack = nil
	activeKey = nil
end

-- Resolves which clip key a state should be playing, given its variant. Returns nil for a state with
-- no clip of its own, which is the common case (see STATE_CLIPS' own note).
local function resolveKey(stateId: MovementStateId, variant: string?): (string?, boolean, boolean)
	local variantMap = VARIANT_CLIPS[stateId]
	if variantMap and variant then
		local key = variantMap[variant]
		if key then
			local entry = STATE_CLIPS[stateId]
			return key, entry ~= nil and entry.Looped, entry ~= nil and entry.ScalesWithSpeed
		end
	end
	local entry = STATE_CLIPS[stateId]
	if entry then
		return entry.Key, entry.Looped, entry.ScalesWithSpeed
	end
	if variantMap then
		-- A variant-driven state with no variant resolved yet (the transition frame can legitimately
		-- reach here before the state's Enter has published one). Playing an arbitrary variant would
		-- be worse than playing nothing for one frame.
		return nil, false, false
	end
	return nil, false, false
end

-- Called on every state transition. Stops whatever was playing and starts whatever the new state
-- wants, or nothing.
function ParkourAnimator.OnStateChanged(_previous: MovementStateId, next: MovementStateId, variant: string?): ()
	local key, looped, scalesWithSpeed = resolveKey(next, variant)
	if key == activeKey then
		return
	end
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
	protectedTrackCall(key, "Play", function()
		track.Looped = looped
		track:Play(ANIMATION.FadeInSeconds)
	end)
end

-- Per-frame speed feed, so a looping movement clip plays at a cadence that matches how fast the
-- character is actually going. A no-op for clips that don't scale, which is most of them -- a vault
-- should take the time the vault takes regardless of approach speed, or the traversal animation and
-- the kinematic path it accompanies would drift apart.
function ParkourAnimator.SetMotion(planarSpeed: number): ()
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
