--!strict
--[[
	AnimationManager.lua

	Owns: EVERY AnimationTrack a single rig plays -- loading them, deciding which of the competing
	requests actually gets the body, starting/crossfading/stopping them, noticing when one falls off
	its own track, and tearing every last one of them down when that rig dies or goes away. One
	instance per rig (the local player's character, a bot, an NPC); nothing else in the codebase
	touches an AnimationTrack directly.

	WHY THIS EXISTS. Animation used to be four independent modules -- Client/FX/CombatAnimator.lua
	(locomotion), Client/FX/FlightAnimator.lua, Client/FX/EmoteAnimator.lua and Client/Parkour/
	ParkourAnimator.lua -- each with its OWN `tracks` dict, its OWN BindCharacter, its OWN Heartbeat
	connection, and its own private copy of the same five mechanics. That shape has three structural
	problems no amount of care inside any one file can fix:

	  1. NOBODY ARBITRATED. Two modules could hold the body at once, and the only defences were
	     hand-wired peepholes between files: CombatAnimator read the Flying Attribute so it wouldn't
	     blend a walk cycle under a flight pose, RunController pushed SetLocomotionSuppressed so a
	     vault wouldn't play a walk underneath it, and parkour clips loaded at Movement priority
	     purely so combat clips would out-rank them. Every one of those is the same missing concept --
	     "who owns this body right now" -- solved a different ad-hoc way, and every new animation
	     source meant another peephole into every existing module. Here that is one mechanism: a
	     LAYER, with ranked CLAIMS on it, resolved in one place (see resolveLayer).

	  2. A STOPPED TRACK STAYED STOPPED. Every one of those modules played a track and trusted it to
	     keep playing. Roblox does not offer that guarantee -- the default Animate script re-asserts
	     its own walk/run track's weight on every Humanoid movement-state change (which is why
	     DominantWeight and the per-frame AdjustWeight re-assert exist at all), a track can be stopped
	     out from under its owner, and AnimationTrack.Speed persists across Stop()/Play() so a track
	     frozen by a hit-stop that then stopped mid-freeze played frozen FOREVER after (the defect
	     Tests/FX/AnimationFreezeGuard.spec.lua was written for). Every one of those was silent: no
	     error, no warning, just a character that stopped animating until it respawned. The Step()
	     watchdog below re-derives the truth every frame and repairs it.

	  3. DEATH AND RESET WERE NOBODY'S JOB. Not one of the four watched Humanoid.Died, Health, or the
	     character being destroyed. A player who died mid-slide kept the slide loop running on the
	     corpse; a one-shot emote whose track never fired Stopped left the server holding that player
	     at WalkSpeed 0 until EmoteConstants.MaxOneShotSeconds bailed it out. Lifecycle here is a
	     first-class phase (Unbound/Live/Dead -- see bindLifecycle), and every path out of Live tears
	     down every track, every connection and every pending timer as a unit.

	THE MODEL, in four sentences. A LAYER is one exclusive slot on the body ("Locomotion",
	"Traversal", "FullBody" -- callers name their own; see Client/FX/LocalAnimator.lua for the ones
	this game uses). A CLAIM is one source saying "I would like this clip on this layer, at this
	rank" -- claims are STICKY state, not events, so a source pushes the same claim every frame if it
	likes and only a genuine change costs anything. Resolution picks the highest-ranked claim per
	layer and crossfades to it, which means mutual exclusion is structural rather than something four
	files have to remember to negotiate. A non-looped claim RETIRES ITSELF when its clip ends, so
	"play this once and give the layer back" needs no timer at the call site.

	CHECKS AND BALANCES -- every one of these is a bug this codebase actually shipped at least once:
	  * Death gate. Claims are refused (and every playing track stopped) once the rig is Dead, unless
	    the claim explicitly sets AllowWhileDead -- that flag exists so a death animation itself can
	    still play.
	  * Rebind invalidation. Every bind bumps a generation; every delayed callback, every track and
	    every connection is checked against the generation that created it, so nothing from a previous
	    life can act on the current one.
	  * Loop repair, with a circuit breaker. A looped track found not playing is restarted -- but no
	    more than MAX_REPAIRS_PER_WINDOW times per REPAIR_WINDOW_SECONDS, after which the claim is
	    dropped with one warning. A repair loop that fights something else every frame is worse than
	    no animation.
	  * One-shot expiry. A non-looped track that outlives its own Length (plus grace) is finalised
	    anyway. AnimationTrack.Stopped is the fast path; this is the backstop that means a missed
	    signal costs a frame, not a stuck emote.
	  * Freeze that cannot strand. Hit-stop freezes are generation-guarded AND recorded once per
	    freeze chain, so overlapping freezes extend the hold rather than restoring each other to the
	    zero the first one wrote (the exact defect the freeze regression tests cover).
	  * Every track operation is pcall'd. Not defensive habit: ParkourController.step runs this whole
	    module inside a pcall whose failure handler releases the movement motor, so an unhandled throw
	    from a bad asset does not lose an animation, it drops the character's motor on the floor. A
	    failing clip costs one warning and one dropped claim, never movement.

	NO LEAKS, stated precisely, because "no leaks" is otherwise unfalsifiable. Per rig at rest this
	module holds: one connection per lifecycle signal (five, all in one bag, all disconnected as a
	unit), one Stopped connection per ACTIVE layer (at most one per layer, disconnected before any
	induced stop and on every teardown path), one AnimationTrack per clip actually played this life
	(destroyed on unbind), and zero timers -- freezes use a generation counter rather than a
	cancellable handle, so a superseded timer returns without touching anything. Animation INSTANCES
	are pooled at module scope and shared across every rig and every life (they are immutable data
	and safe to share), so a respawn allocates no Instances at all.

	Does not own: WHEN anything should play. Not one line here knows what a slide, a sprint or an
	emote is -- callers push claims, this resolves and executes them. It also does not own the frame
	loop unless asked to (Step is public; `Stepping = "Heartbeat"` is a convenience for a caller that
	has no loop of its own), and it does not own asset ids -- Register/RegisterMany take whatever
	table the caller's own constants file already owns.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local AnimatorUtil = require(ReplicatedStorage.Shared.AnimatorUtil)
local Logger = require(ReplicatedStorage.Shared.Logger)
local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)

local logger = Logger.scope("AnimationManager")

local AnimationManager = {}
AnimationManager.__index = AnimationManager

-- Blend times for a claim that says nothing about its own. Deliberately modest: every caller in this
-- codebase that cares (ParkourConstants.Animation.BlendProfiles, Constants.FX.Animation.Combat/
-- Flight, EmoteConstants.AnimationFade) already owns tuned numbers and passes them per claim, so
-- these only ever apply to a caller that genuinely has no opinion.
local DEFAULT_FADE_IN = 0.1
local DEFAULT_FADE_OUT = 0.1

-- How far past its own Length a one-shot may run before the watchdog finalises it anyway. Generous
-- enough that an ordinary fade-out (the longest in this codebase is ParkourConstants' 0.26s Snap
-- profile) never trips it, tight enough that a genuinely stuck clip is released within a beat.
local ONE_SHOT_GRACE_SECONDS = 0.4

-- Ceiling for a one-shot whose Length never resolved -- Length reads 0 until the asset finishes
-- downloading, so a cold first play legitimately has no duration to expire against. Without a
-- ceiling that clip would occupy its layer forever. Overridable per claim (ClipSpec.MaxSeconds) for
-- the rare clip genuinely longer than this.
local UNKNOWN_LENGTH_MAX_SECONDS = 8

-- Loop-repair circuit breaker. A looped track found stopped is restarted, because that is nearly
-- always Roblox's own Animate script having won a weight fight and the right answer is to take the
-- body back. But if something is genuinely and repeatedly killing the track, restarting it every
-- frame produces a strobing character and a warning per frame; past this budget the claim is dropped
-- once, loudly, and the layer goes quiet instead.
local REPAIR_WINDOW_SECONDS = 1
local MAX_REPAIRS_PER_WINDOW = 4

-- Fade used when death, unbind or destruction stops everything. Fast, but not a hard cut: a corpse
-- snapping out of its last pose in one frame reads worse than a corpse easing out of it, and Roblox's
-- own death physics takes over on roughly this timescale anyway.
local TEARDOWN_FADE_SECONDS = 0.15

export type Phase = "Unbound" | "Live" | "Dead"

-- Why a claim stopped owning its layer. Reported to ClipSpec.OnFinished so a caller can tell the
-- difference between "my emote finished" (Completed -- the only reason Client/Emotes/EmoteController
-- .lua may report a finish to the server) and "something outranked me" (Superseded), which used to be
-- indistinguishable and is the difference between ending an emote correctly and ending it twice.
export type FinishReason =
	-- The clip played to its own natural end. Non-looped claims only.
	"Completed"
	-- A higher-ranked claim, or a replacement claim from the same source, took the layer.
	| "Superseded"
	-- The caller withdrew the claim (Clear/ClearLayer/StopAll).
	| "Cleared"
	-- The watchdog finalised a one-shot that outlived its own Length -- see ONE_SHOT_GRACE_SECONDS.
	| "Expired"
	-- A track operation threw, or the clip could not be loaded at all.
	| "Failed"
	-- The rig died, or the repair budget ran out, or the rig was unbound/destroyed.
	| "Stopped"

export type ClipSpec = {
	-- Registry key (see Register/RegisterMany) or a raw "rbxassetid://" content id. A key with no
	-- registered id, or one registered as "" (this codebase's "authored later" convention), resolves
	-- to no clip and no error -- the claim is simply refused.
	Clip: string,
	-- Rank within the layer; the highest-ranked live claim wins, ties broken by whichever was pushed
	-- most recently. Defaults to 0, which is correct whenever a layer has one obvious owner.
	Rank: number?,
	Looped: boolean?,
	FadeIn: number?,
	FadeOut: number?,
	-- Blend weight. Anything above 1 also implies HoldWeight below unless the caller says otherwise:
	-- a weight raised specifically to out-rank Roblox's own re-asserting Animate script has to be
	-- re-asserted too, or it wins exactly once (Constants.FX.Animation.DominantWeight's own header).
	Weight: number?,
	Speed: number?,
	Priority: Enum.AnimationPriority?,
	HoldWeight: boolean?,
	-- Lets this claim play (and survive) on a Dead rig. Every other claim is refused once the rig
	-- dies; this exists for the death animation itself.
	AllowWhileDead: boolean?,
	-- Expiry ceiling for a one-shot whose Length has not resolved yet -- see
	-- UNKNOWN_LENGTH_MAX_SECONDS.
	MaxSeconds: number?,
	-- For a one-shot the SERVER plays on a rig clients watch (a bot, or a player's character through
	-- GrabSystem). AnimationTrack.Looped does not replicate -- every client plays the track with the loop
	-- flag saved in the asset -- and a one-shot that ends by itself on the server sends clients no stop.
	-- So a clip exported looped, played "once" from the server, played forever on every screen. With this
	-- set the track plays looped everywhere (agreeing with any asset), and Step stops it explicitly, while
	-- it is still playing, at the end of its first pass; an explicit Stop of a playing track DOES replicate.
	-- Reported as Completed, like any one-shot. Ignored when Looped is set.
	ReplicatedOneShot: boolean?,
	OnFinished: ((clip: string, reason: FinishReason) -> ())?,
}

type Claim = {
	Layer: string,
	Source: string,
	Spec: ClipSpec,
	Rank: number,
	-- Monotonic push order, used only to break rank ties in favour of the newer claim.
	Sequence: number,
}

type ActiveEntry = {
	Layer: string,
	Source: string,
	Clip: string,
	Track: AnimationTrack,
	Spec: ClipSpec,
	Looped: boolean,
	FadeOut: number,
	Weight: number,
	HoldWeight: boolean,
	-- What Speed this entry SHOULD be playing at. Kept separate from track.Speed so a freeze (which
	-- writes 0) and a per-frame speed feed (SetSpeed) cannot overwrite each other -- the freeze
	-- restores to this, and SetSpeed while frozen updates only this.
	DesiredSpeed: number,
	StartedAt: number,
	Stopped: RBXScriptConnection?,
	-- Loop-repair budget, see REPAIR_WINDOW_SECONDS.
	Repairs: number,
	RepairWindowStartedAt: number,
	-- ClipSpec.ReplicatedOneShot on a one-shot: the track is looped underneath and Step ends it. The
	-- playhead last frame, so a pass that wrapped between two Steps is still caught.
	ExplicitEnd: boolean,
	LastPosition: number,
	-- Set the instant this entry stops owning its layer, so a Stopped signal already in flight (or a
	-- watchdog pass on the same frame) cannot finalise it twice.
	Retired: boolean,
}

export type ManagerOptions = {
	-- Names this manager in every log line. A rig with no name is indistinguishable from another in
	-- Output, which matters the moment there is more than one (a player plus three bots).
	Name: string?,
	-- "Heartbeat" (default) connects and owns one RunService.Heartbeat that calls Step; "Manual"
	-- leaves stepping to the caller, which is what the spec suite uses to drive frames deterministically.
	Stepping: ("Heartbeat" | "Manual")?,
	-- Injection seam for tests: given the bound Animator and a resolved content id, return a track.
	-- Defaults to a pcall'd Animator:LoadAnimation against the pooled Animation instance. Exists
	-- because every AnimationId in this game currently ships as "" (the authored-later convention), so
	-- a spec cannot load a real track to assert against.
	LoadTrack: ((animator: Animator, clip: string, assetId: string) -> AnimationTrack?)?,
}

export type AnimationManagerInstance = typeof(setmetatable(
	{} :: {
		name: string,
		phase: Phase,
		-- Bumped by every Bind and every Unbind. Anything that captured a generation -- a delayed
		-- freeze restore, a Stopped connection, a loaded track -- checks it before acting, so work
		-- scheduled by a previous life can never touch the current one.
		generation: number,
		character: Model?,
		humanoid: Humanoid?,
		animator: Animator?,
		registry: { [string]: string },
		-- Every track loaded for the CURRENT bind, keyed by clip. Dropped and destroyed wholesale on
		-- unbind: a track belongs to the Animator it was loaded from, so one from a previous life is
		-- dead weight that would never play again.
		tracks: { [string]: AnimationTrack },
		claims: { [string]: { [string]: Claim } },
		active: { [string]: ActiveEntry },
		sequence: number,
		lifecycle: { RBXScriptConnection },
		stepConnection: RBXScriptConnection?,
		-- Freeze bookkeeping -- see Freeze. frozen maps every track this manager currently holds
		-- frozen to the speed it was playing at BEFORE the first freeze in the current chain, so
		-- overlapping freezes cannot record the 0 an earlier freeze already wrote.
		frozen: { [AnimationTrack]: number },
		freezeGeneration: number,
		loadTrack: (animator: Animator, clip: string, assetId: string) -> AnimationTrack?,
	},
	AnimationManager
))

-- Animation instances keyed by content id, shared by every manager, every rig and every life. An
-- Animation is immutable data (a name and an id) and Animator:LoadAnimation does not take ownership
-- of it, so one instance can back every track in the game -- which is what makes a respawn allocate
-- no Instances at all. The four modules this replaces each built and held their own set, so the same
-- id could exist three times over.
local templatePool: { [string]: Animation } = {}

local function getTemplate(assetId: string): Animation
	local existing = templatePool[assetId]
	if existing then
		return existing
	end
	local animation = Instance.new("Animation")
	animation.Name = assetId
	animation.AnimationId = assetId
	templatePool[assetId] = animation
	return animation
end

local function defaultLoadTrack(animator: Animator, clip: string, assetId: string): AnimationTrack?
	local ok, trackOrError = pcall(function()
		return animator:LoadAnimation(getTemplate(assetId))
	end)
	if not ok then
		logger:warn("Failed to load animation", { clip = clip, errorMessage = tostring(trackOrError) })
		return nil
	end
	return trackOrError :: AnimationTrack
end

--[[
	Runs one AnimationTrack operation such that it cannot take its caller's frame down with it.

	Load-bearing rather than habitual: Client/Parkour/ParkourController.step calls into this module
	from inside a pcall whose failure handler calls ParkourMotor.Release(), which destroys the
	LinearVelocity rig a Velocity-driven state is being driven by. An error thrown by a track
	operation there does not lose a clip, it drops the character's motor -- and if the throw repeats
	every frame, the state can never drive the body at all. Sliding and wall-running are the sharp
	edges, since they are the only clips whose speed is written every frame rather than once.

	Returns false on failure so callers can retire the claim rather than poke the same broken track
	again next frame.
]]
local function reportOperationFailure(clip: string, what: string, errorMessage: unknown): ()
	logger:warn("Animation operation failed -- dropping the clip, gameplay continues", {
		clip = clip,
		operation = what,
		errorMessage = tostring(errorMessage),
	})
end

local function protectedCall(clip: string, what: string, operation: () -> ()): boolean
	local ok, errorMessage = pcall(operation)
	if ok then
		return true
	end
	reportOperationFailure(clip, what, errorMessage)
	return false
end

-- Hoisted to module scope purely so SetSpeed can hand it to pcall as a plain function value.
--
-- Every other protectedCall site below builds a closure at the call site, which is right for them:
-- they run on an event (a claim, a freeze, a repair) and the closure captures three or four locals
-- that would otherwise need threading through. SetSpeed is the exception -- it is called EVERY FRAME
-- by Client/Parkour/ParkourAnimator.lua for the whole length of a sprint, wall-run or slide, times
-- three manager instances -- so a closure there is a heap allocation per frame per manager for a
-- one-line body with two arguments.
local function adjustTrackSpeed(track: AnimationTrack, speed: number): ()
	track:AdjustSpeed(speed)
end

--[[
	Creates a manager for one rig. Nothing is bound yet -- call Bind(character) for that, once per
	life. Constructing a manager is cheap and allocation-free beyond the instance itself, so a caller
	that owns several rigs (a bot pool) should hold one per rig rather than trying to share one.
]]
function AnimationManager.new(options: ManagerOptions?): AnimationManagerInstance
	local resolved: ManagerOptions = options or {}
	local self = setmetatable({
		name = resolved.Name or "AnimationManager",
		phase = "Unbound" :: Phase,
		generation = 0,
		character = nil,
		humanoid = nil,
		animator = nil,
		registry = {},
		tracks = {},
		claims = {},
		active = {},
		sequence = 0,
		lifecycle = {},
		stepConnection = nil,
		frozen = {},
		freezeGeneration = 0,
		loadTrack = resolved.LoadTrack or defaultLoadTrack,
	}, AnimationManager) :: AnimationManagerInstance

	if (resolved.Stepping or "Heartbeat") == "Heartbeat" then
		self.stepConnection = RunService.Heartbeat:Connect(function(deltaTime: number)
			self:Step(deltaTime)
		end)
	end

	return self
end

--[[
	REGISTRY. Maps a clip key to a content id. Callers register whatever table their own constants
	file already owns (CombatConstants.AnimationIds, ParkourConstants.AnimationIds, an EmoteRegistry
	sweep), so this module never becomes a second place asset ids live.

	An id of "" is registered as absent, not as a broken id: this codebase's convention is that a
	wired-but-unauthored clip ships as an empty string, and every path here degrades to "no clip" for
	one, exactly as the four modules this replaces each did.
]]
function AnimationManager.Register(self: AnimationManagerInstance, clip: string, assetId: string): ()
	if assetId == "" then
		self.registry[clip] = nil
		return
	end
	self.registry[clip] = assetId
end

function AnimationManager.RegisterMany(self: AnimationManagerInstance, ids: { [string]: string }): ()
	for clip, assetId in ids do
		self:Register(clip, assetId)
	end
end

-- Every distinct content id this manager could ever play, for Client/Loading/AssetPreloader.lua's
-- boot-time warm pass. Raw id strings rather than Animation instances, because handing out the
-- pooled instances would invite a caller to mutate one that every other rig in the game is sharing.
-- NOT because a bare id can be preloaded directly -- it cannot; ContentProvider:PreloadAsync reports
-- Failure for one. AssetPreloader wraps each id returned here in a throwaway Animation of its own
-- (see animationFor there), which is both correct and the reason this function can keep returning
-- ids instead of surrendering its templates.
function AnimationManager.GetPreloadIds(self: AnimationManagerInstance): { string }
	local ids: { string } = {}
	local seen: { [string]: true } = {}
	for _, assetId in self.registry do
		if not seen[assetId] then
			seen[assetId] = true
			table.insert(ids, assetId)
		end
	end
	return ids
end

local function resolveAssetId(self: AnimationManagerInstance, clip: string): string?
	local registered = self.registry[clip]
	if registered then
		return registered
	end
	-- Unregistered keys that are themselves content ids are accepted directly, so a caller with one
	-- ad-hoc clip does not have to register it first. Anything else is an unauthored slot.
	if string.match(clip, "^rbxassetid://") then
		return clip
	end
	return nil
end

-- Loads (and caches, for this bind) the track for a clip. Lazy rather than eager: most lives never
-- touch most clips, so a respawn that preloaded all forty would pay for thirty-eight it never plays.
local function getTrack(self: AnimationManagerInstance, clip: string): AnimationTrack?
	local existing = self.tracks[clip]
	if existing then
		return existing
	end
	local animator = self.animator
	if not animator then
		return nil
	end
	local assetId = resolveAssetId(self, clip)
	if not assetId then
		return nil
	end
	local track = self.loadTrack(animator, clip, assetId)
	if not track then
		return nil
	end
	self.tracks[clip] = track
	return track
end

--[[
	Retires an entry: disconnects its Stopped watch BEFORE any induced stop (so a stop this module
	causes can never be mistaken for the clip finishing on its own -- the distinction Client/Emotes/
	EmoteController.lua reports to the server), stops the track if asked, and reports the reason
	exactly once.

	`stopTrack` is false only when the track stopped by itself, which is the one case where calling
	Stop would be both pointless and a second Stopped signal.
]]
local function retire(self: AnimationManagerInstance, entry: ActiveEntry, reason: FinishReason, stopTrack: boolean): ()
	if entry.Retired then
		return
	end
	entry.Retired = true

	local stopped = entry.Stopped
	if stopped then
		stopped:Disconnect()
		entry.Stopped = nil
	end

	if self.active[entry.Layer] == entry then
		self.active[entry.Layer] = nil
	end

	if stopTrack then
		local track = entry.Track
		local fadeOut = entry.FadeOut
		protectedCall(entry.Clip, "Stop", function()
			track:Stop(fadeOut)
		end)
	end

	-- A frozen track that is going away must not stay in the freeze ledger: the pending restore would
	-- otherwise write a speed onto a track nothing is playing any more, and -- worse -- a track left
	-- in the ledger is never released, so its entry in `frozen` outlives the entry that put it there.
	self.frozen[entry.Track] = nil

	local onFinished = entry.Spec.OnFinished
	if onFinished then
		-- pcall'd for the same reason every track operation is: this callback runs inside whatever
		-- frame retired the entry -- often ParkourController.step's own pcall -- and a caller's mistake
		-- must not become this module's failure, nor abort the rest of a teardown sweep.
		local ok, errorMessage = pcall(onFinished, entry.Clip, reason)
		if not ok then
			logger:warn("OnFinished callback threw", {
				clip = entry.Clip,
				reason = reason,
				errorMessage = tostring(errorMessage),
			})
		end
	end
end

-- Starts `claim` on its layer. Assumes the layer is already free (resolveLayer retires the previous
-- entry first, which is what makes a transition a genuine crossfade: the outgoing clip is still
-- fading down at falling weight while this one fades up).
local function start(self: AnimationManagerInstance, claim: Claim): ()
	local spec = claim.Spec
	local clip = spec.Clip

	if self.phase ~= "Live" and not spec.AllowWhileDead then
		return
	end

	local track = getTrack(self, clip)
	if not track then
		-- No asset authored yet, or the load failed. Reported as an immediate finish rather than
		-- silence: a caller waiting on OnFinished to release a lock (an emote holding the player's
		-- WalkSpeed at 0 server-side) would otherwise wait for a clip that is never going to play.
		local onFinished = spec.OnFinished
		if onFinished then
			pcall(onFinished, clip, "Failed" :: FinishReason)
		end
		return
	end

	local looped = spec.Looped == true
	local explicitEnd = not looped and spec.ReplicatedOneShot == true
	local weight = spec.Weight or 1
	local speed = spec.Speed or 1
	local fadeIn = spec.FadeIn or DEFAULT_FADE_IN
	local now = os.clock()

	local entry: ActiveEntry = {
		Layer = claim.Layer,
		Source = claim.Source,
		Clip = clip,
		Track = track,
		Spec = spec,
		Looped = looped,
		FadeOut = spec.FadeOut or DEFAULT_FADE_OUT,
		Weight = weight,
		-- A weight above 1 is only ever asked for to out-rank Roblox's own Animate script, and that
		-- script re-asserts its own weight on every Humanoid movement-state change -- so a raised
		-- weight that is not held wins exactly once and then quietly loses. Holding it is what the
		-- caller meant; an explicit HoldWeight still overrides in either direction.
		HoldWeight = if spec.HoldWeight ~= nil then spec.HoldWeight else weight > 1,
		DesiredSpeed = speed,
		StartedAt = now,
		Stopped = nil,
		Repairs = 0,
		RepairWindowStartedAt = now,
		ExplicitEnd = explicitEnd,
		LastPosition = 0,
		Retired = false,
	}

	-- Published BEFORE the play attempt so a throw inside it finds the entry and can retire it. An
	-- entry left unpublished after a failed play would be invisible to every teardown path while its
	-- track kept whatever state the failure left behind.
	self.active[claim.Layer] = entry

	local played = protectedCall(clip, "Play", function()
		track.Looped = looped or explicitEnd
		if spec.Priority then
			track.Priority = spec.Priority
		end
		track:Play(fadeIn, weight, speed)
	end)
	if not played then
		-- The track is broken, not the claim: drop it from the cache so a later claim reloads it
		-- rather than inheriting the same failure, and withdraw the claim so this does not repeat
		-- every frame.
		self.tracks[clip] = nil
		retire(self, entry, "Failed", false)
		local layerClaims = self.claims[claim.Layer]
		if layerClaims then
			layerClaims[claim.Source] = nil
		end
		return
	end

	-- Fast path for "this clip ended". The watchdog in Step is the backstop; this is what makes the
	-- report prompt. Retired entries are ignored, which is what keeps an induced stop (a supersede, a
	-- teardown) from being reported as a natural completion -- and the connection is disconnected in
	-- retire() before any induced Stop, so in practice this never even fires for one.
	entry.Stopped = track.Stopped:Connect(function()
		if entry.Retired or self.active[claim.Layer] ~= entry then
			return
		end
		if entry.Looped then
			-- A looped track is not supposed to reach Stopped at all. Leave it to the watchdog's
			-- repair path, which owns the "should this come back" decision and its budget.
			return
		end
		retire(self, entry, "Completed", false)
	end)
end

-- Picks the winning claim for one layer and makes the body match it. The single place in this
-- codebase where "who owns this body right now" is decided.
local function resolveLayer(self: AnimationManagerInstance, layer: string): ()
	local layerClaims = self.claims[layer]
	local winner: Claim? = nil
	if layerClaims then
		for _, claim in layerClaims do
			if
				winner == nil
				or claim.Rank > winner.Rank
				-- Equal rank goes to whoever pushed most recently. Two sources at the same rank are
				-- already a caller-side modelling mistake; making it deterministic beats making it
				-- depend on table iteration order.
				or (claim.Rank == winner.Rank and claim.Sequence > winner.Sequence)
			then
				winner = claim
			end
		end
	end

	local current = self.active[layer]
	if current and winner and current.Source == winner.Source and current.Clip == winner.Spec.Clip then
		-- Same source, same clip: this is a re-push of a sticky claim, not a transition. Adopt any
		-- changed playback numbers in place rather than restarting the clip -- restarting a slide loop
		-- because its speed changed is exactly the visible hitch this model exists to remove.
		current.Spec = winner.Spec
		current.FadeOut = winner.Spec.FadeOut or current.FadeOut
		local speed = winner.Spec.Speed
		if speed and speed ~= current.DesiredSpeed then
			self:SetSpeed(layer, speed)
		end
		return
	end

	if current then
		retire(self, current, "Superseded", true)
	end
	if winner then
		start(self, winner)
	end
end

--[[
	Pushes (or replaces) one source's claim on one layer. STICKY: the claim stands until the same
	source pushes a different one or clears it, so a per-frame caller may push the same claim every
	frame at the cost of one table comparison, and a transition-driven caller may push once and forget.

	Refused outright on a Dead or Unbound rig unless the spec sets AllowWhileDead -- see the death
	gate in this file's header.
]]
function AnimationManager.Claim(self: AnimationManagerInstance, layer: string, source: string, spec: ClipSpec): ()
	if self.phase ~= "Live" and not spec.AllowWhileDead then
		return
	end

	local layerClaims = self.claims[layer]
	if not layerClaims then
		layerClaims = {}
		self.claims[layer] = layerClaims
	end

	self.sequence += 1
	layerClaims[source] = {
		Layer = layer,
		Source = source,
		Spec = spec,
		Rank = spec.Rank or 0,
		Sequence = self.sequence,
	}
	resolveLayer(self, layer)
end

--[[
	Withdraws one source's claim. The layer then falls back to whatever lower-ranked claim is still
	standing, which is the whole point of ranks: flight releasing the Locomotion layer hands it back
	to the ground locomotion claim underneath without either module knowing the other exists.
]]
function AnimationManager.Clear(self: AnimationManagerInstance, layer: string, source: string): ()
	local layerClaims = self.claims[layer]
	if not layerClaims or not layerClaims[source] then
		return
	end
	layerClaims[source] = nil
	local current = self.active[layer]
	if current and current.Source == source then
		retire(self, current, "Cleared", true)
	end
	resolveLayer(self, layer)
end

-- Convenience for the common "this source either wants a clip or wants nothing" shape, which is what
-- every per-frame evaluator in this codebase actually computes.
function AnimationManager.SetClaim(self: AnimationManagerInstance, layer: string, source: string, spec: ClipSpec?): ()
	if spec then
		self:Claim(layer, source, spec)
	else
		self:Clear(layer, source)
	end
end

-- Drops every claim on a layer and stops whatever it was playing.
function AnimationManager.ClearLayer(self: AnimationManagerInstance, layer: string): ()
	self.claims[layer] = nil
	local current = self.active[layer]
	if current then
		retire(self, current, "Cleared", true)
	end
end

--[[
	Per-frame playback-rate feed for the active clip on a layer -- so a loop whose cadence should
	track how fast the character is actually moving (a slide, a wall-run) can be driven without
	re-pushing a whole claim.

	Written through DesiredSpeed rather than straight onto the track, so a hit-stop freeze holding
	that track at 0 is not fought frame by frame: the freeze restores to whatever DesiredSpeed says
	when it elapses.
]]
function AnimationManager.SetSpeed(self: AnimationManagerInstance, layer: string, speed: number): ()
	local entry = self.active[layer]
	if not entry or entry.Retired then
		return
	end
	local track = entry.Track

	-- DEDUPED, and against BOTH numbers rather than just DesiredSpeed -- which is the difference
	-- between a dedupe and a silently broken repair. ParkourAnimator calls this every frame with a
	-- value that usually has not changed, so the common case should cost two compares; but Step's own
	-- watchdog (see the Repair pass) calls SetSpeed(layer, entry.DesiredSpeed) precisely to push a
	-- value that ALREADY equals DesiredSpeed back onto a track it found sitting at 0. Comparing only
	-- DesiredSpeed would turn that repair into a no-op and leave the clip frozen with nothing in the
	-- log to say why.
	if entry.DesiredSpeed == speed and track.Speed == speed then
		return
	end

	entry.DesiredSpeed = speed
	-- Written through DesiredSpeed above rather than straight onto the track, so a hit-stop freeze
	-- holding that track at 0 is not fought frame by frame: the freeze restores to whatever
	-- DesiredSpeed says when it elapses.
	if self.frozen[track] ~= nil then
		return
	end

	-- pcall'd directly rather than through protectedCall, to keep this per-frame path free of the
	-- closure that wrapper's signature would require -- see adjustTrackSpeed. Same failure handling,
	-- same log line.
	local ok, errorMessage = pcall(adjustTrackSpeed, track, speed)
	if not ok then
		reportOperationFailure(entry.Clip, "AdjustSpeed", errorMessage)
	end
end

function AnimationManager.GetActiveClip(self: AnimationManagerInstance, layer: string): string?
	local entry = self.active[layer]
	return if entry then entry.Clip else nil
end

-- Where the clip on `layer` is: its playhead and its Length, both in the clip's own seconds, or nil when
-- the layer is empty. Length reads 0 until the asset has loaded, so a caller comparing against it has to
-- treat 0 as "not yet known". For a caller that acts at a point INSIDE a clip rather than at its end
-- (GrabSystem releasing a thrown body partway through the throw clip).
function AnimationManager.GetPlayback(self: AnimationManagerInstance, layer: string): (number?, number)
	local entry = self.active[layer]
	if not entry or entry.Retired then
		return nil, 0
	end
	local track = entry.Track
	return track.TimePosition, track.Length
end

function AnimationManager.GetPhase(self: AnimationManagerInstance): Phase
	return self.phase
end

--[[
	FREEZE -- the animation half of a hit-stop or landing-impact freeze frame. Holds every currently
	playing track (optionally only those on `layers`) at speed 0 for `seconds`, then restores each to
	its own DesiredSpeed.

	Three specific ways this used to break, all silent, all covered by the spec suite:
	  a) An overlapping freeze re-sampled the pre-freeze speed off tracks the FIRST freeze had already
	     zeroed and recorded 0 as the original -- and 0 is truthy in Lua, so an `or 1` fallback never
	     fired and every track restored to 0, i.e. froze forever. The ledger is per manager and
	     recorded once per chain, so a nested freeze extends the hold instead of poisoning it.
	  b) The restore was gated on IsPlaying. Speed persists across Stop()/Play(), so a track frozen and
	     then stopped mid-hold kept Speed 0 and played frozen every subsequent time it started. The
	     restore here is unconditional over exactly the tracks this manager froze.
	  c) A no-op freeze (nothing playing) bumped the generation anyway and orphaned an earlier pending
	     restore, stranding its tracks at 0. A freeze that holds nothing returns without touching the
	     generation.
]]
function AnimationManager.Freeze(self: AnimationManagerInstance, seconds: number, layers: { string }?): ()
	local generation = self.generation
	local held = false

	for layer, entry in self.active do
		if layers and not table.find(layers, layer) then
			continue
		end
		local track = entry.Track
		if self.frozen[track] ~= nil then
			-- Already held by an earlier freeze whose restore has not fired. Its true pre-freeze speed
			-- is already recorded, so do NOT re-sample it -- just let this newer freeze take ownership
			-- of the restore below, which extends the hold rather than resuming mid-freeze.
			held = true
		elseif entry.Track.IsPlaying then
			self.frozen[track] = entry.DesiredSpeed
			held = protectedCall(entry.Clip, "Freeze", function()
				track:AdjustSpeed(0)
			end) or held
		end
	end

	if not held then
		return
	end

	self.freezeGeneration += 1
	local freezeGeneration = self.freezeGeneration
	task.delay(seconds, function()
		-- Superseded by a newer freeze (which owns the restore now), or by a rebind/teardown that
		-- already released everything. Either way this timer must not write a speed onto anything.
		if self.freezeGeneration ~= freezeGeneration or self.generation ~= generation then
			return
		end
		self:Thaw()
	end)
end

-- Restores every track this manager currently holds frozen. Public because a teardown, a death, or a
-- caller that wants to cancel a hold early all need it, and because it is the one operation that must
-- be idempotent -- calling it with nothing frozen is a no-op, not an error.
function AnimationManager.Thaw(self: AnimationManagerInstance): ()
	for track, speed in self.frozen do
		protectedCall("<frozen>", "Thaw", function()
			track:AdjustSpeed(speed)
		end)
	end
	table.clear(self.frozen)
end

--[[
	THE WATCHDOG. Called once per frame (by this manager's own Heartbeat, or by the caller under
	Stepping = "Manual"). Re-derives what should be true of every active track and repairs what is
	not, which is the difference between an animation system that plays clips and one that KEEPS them
	playing.

	Four repairs, each for a failure this codebase has actually shipped:
	  * Weight re-assert. Roblox's default Animate script re-asserts its own track's weight on every
	    Humanoid movement-state change, so a raised weight applied once at Play() loses the tie a
	    moment later and the character reads as fighting its own animation.
	  * Loop repair. A looped track found not playing is restarted, on a budget (see
	    MAX_REPAIRS_PER_WINDOW) so a genuinely contested track goes quiet instead of strobing.
	  * Speed repair. A track sitting at 0 while nothing has it frozen is the "frozen forever" defect;
	    it is written back to DesiredSpeed rather than waiting for a respawn to clear it.
	  * One-shot expiry. A non-looped track that has outlived its own Length plus grace is finalised,
	    so a missed Stopped signal costs one frame rather than a permanently occupied layer -- and so a
	    caller waiting on OnFinished (an emote holding a server-side movement lock) is always released.
]]
function AnimationManager.Step(self: AnimationManagerInstance, _deltaTime: number?): ()
	if self.phase == "Unbound" then
		return
	end

	local now = os.clock()

	for layer, entry in self.active do
		if entry.Retired then
			continue
		end

		local track = entry.Track
		local frozen = self.frozen[track] ~= nil
		local playing = track.IsPlaying

		if playing then
			if entry.HoldWeight then
				protectedCall(entry.Clip, "AdjustWeight", function()
					track:AdjustWeight(entry.Weight)
				end)
			end
			-- Speed 0 with nothing holding it frozen is a stranded freeze restore, the exact state
			-- that used to persist until the next respawn.
			if not frozen and track.Speed == 0 and entry.DesiredSpeed ~= 0 then
				logger:debug("Repairing a track stranded at speed 0", { clip = entry.Clip, layer = layer })
				self:SetSpeed(layer, entry.DesiredSpeed)
			end
		end

		if entry.Looped then
			if not playing then
				-- Budget window rolls forward, so ordinary isolated repairs (one per wall-run, say)
				-- never accumulate toward the breaker.
				if now - entry.RepairWindowStartedAt > REPAIR_WINDOW_SECONDS then
					entry.RepairWindowStartedAt = now
					entry.Repairs = 0
				end
				entry.Repairs += 1
				if entry.Repairs > MAX_REPAIRS_PER_WINDOW then
					logger:warn("Loop clip will not stay playing -- dropping the claim", {
						clip = entry.Clip,
						layer = layer,
						source = entry.Source,
					})
					local layerClaims = self.claims[layer]
					if layerClaims then
						layerClaims[entry.Source] = nil
					end
					retire(self, entry, "Stopped", true)
					continue
				end
				local restarted = protectedCall(entry.Clip, "Repair", function()
					track:Play(entry.FadeOut, entry.Weight, entry.DesiredSpeed)
				end)
				if not restarted then
					retire(self, entry, "Failed", false)
				end
			end
		elseif not frozen then
			-- Length reads 0 until the asset has finished downloading, so a cold first play expires
			-- against the caller's own ceiling instead. Divided by speed because a half-speed clip
			-- genuinely takes twice as long.
			local speed = math.abs(entry.DesiredSpeed)
			local length = track.Length
			-- ReplicatedOneShot: end the first pass ourselves, a fade-out early so the fade finishes on the
			-- clip's own last frame rather than bleeding into the start of a second pass.
			if entry.ExplicitEnd and length > 0 then
				local position = track.TimePosition
				local wrapped = position < entry.LastPosition
				entry.LastPosition = position
				local fade = math.min(entry.FadeOut * speed, length * 0.25)
				if wrapped or position >= length - fade then
					local layerClaims = self.claims[layer]
					if layerClaims then
						layerClaims[entry.Source] = nil
					end
					retire(self, entry, "Completed", true)
					continue
				end
			end
			local limit = if length > 0 and speed > 0
				then length / speed + ONE_SHOT_GRACE_SECONDS
				else entry.Spec.MaxSeconds or UNKNOWN_LENGTH_MAX_SECONDS
			if now - entry.StartedAt > limit then
				logger:debug("One-shot outlived its own length -- finalising", { clip = entry.Clip, layer = layer })
				local layerClaims = self.claims[layer]
				if layerClaims then
					layerClaims[entry.Source] = nil
				end
				retire(self, entry, "Expired", true)
			end
		end
	end
end

-- Stops every active track and reports every claim as finished. The single teardown path shared by
-- death, unbind and destruction, so none of them can grow its own partial version.
local function stopAll(self: AnimationManagerInstance, reason: FinishReason): ()
	self:Thaw()
	for _, entry in self.active do
		entry.FadeOut = math.min(entry.FadeOut, TEARDOWN_FADE_SECONDS)
		retire(self, entry, reason, true)
	end
	table.clear(self.active)
	table.clear(self.claims)
end

local function disconnectLifecycle(self: AnimationManagerInstance): ()
	for _, connection in self.lifecycle do
		connection:Disconnect()
	end
	table.clear(self.lifecycle)
end

-- Marks the rig dead: everything stops, every claim is dropped, and new claims are refused until the
-- next Bind. Idempotent, because all three signals that can raise it (Died, Health hitting 0, the
-- Humanoid entering the Dead state) routinely fire for the same death.
local function markDead(self: AnimationManagerInstance): ()
	if self.phase ~= "Live" then
		return
	end
	self.phase = "Dead"
	logger:debug("Rig died -- stopping every track", { rig = self.name })
	stopAll(self, "Stopped")
end

--[[
	Binds this manager to a character, ending whatever life it was bound to before. One call per life,
	from whoever owns character lifecycle (Client/FX/LocalAnimator.lua for the local player).

	Watches five signals, all in one bag disconnected as a unit by Unbind:
	  * Humanoid.Died and Humanoid.HealthChanged -- the death gate. Both, not one: Died is the precise
	    signal, but a character bound at exactly the wrong moment, or one killed by a direct Health
	    write on a rig whose Died has already fired, is caught by the health check instead.
	  * Humanoid.StateChanged -> Dead -- the third way a rig dies, and the one that fires for a
	    Humanoid killed by physics rather than by a health write.
	  * Humanoid.Destroying and Character.Destroying -- RESET. A player pressing R, an admin
	    respawning someone, or Roblox reaping a corpse destroys the character out from under every
	    track loaded against its Animator, and the tracks are then unreachable garbage still holding
	    this manager's callbacks. This is what turns that into a clean unbind.

	Binding a character that is already dead lands directly in Dead rather than Live, so a manager
	bound to a corpse refuses claims exactly as one whose rig died under it does.
]]
function AnimationManager.Bind(self: AnimationManagerInstance, character: Model): boolean
	self:Unbind()

	self.generation += 1
	local generation = self.generation

	local animator = AnimatorUtil.GetOrCreateAnimator(character)
	local humanoid = CharacterUtil.HumanoidOf(character)
	if not animator or not humanoid then
		logger:warn("Bind: no Humanoid/Animator available", { rig = self.name, character = character.Name })
		return false
	end

	self.character = character
	self.humanoid = humanoid
	self.animator = animator
	self.phase = if humanoid.Health <= 0 then "Dead" else "Live"

	-- Every handler re-checks the generation it was created under: a connection can outlive the bind
	-- that made it by a frame (Disconnect is not retroactive for a signal already in flight), and
	-- acting on the previous life's death would tear down the new one's animations.
	local function guarded(handler: (...any) -> ()): (...any) -> ()
		return function(...)
			if self.generation ~= generation then
				return
			end
			handler(...)
		end
	end

	table.insert(
		self.lifecycle,
		humanoid.Died:Connect(guarded(function()
			markDead(self)
		end))
	)
	table.insert(
		self.lifecycle,
		humanoid.HealthChanged:Connect(guarded(function(health: number)
			if health <= 0 then
				markDead(self)
			end
		end))
	)
	table.insert(
		self.lifecycle,
		humanoid.StateChanged:Connect(guarded(function(_old, new)
			if new == Enum.HumanoidStateType.Dead then
				markDead(self)
			end
		end))
	)
	table.insert(
		self.lifecycle,
		humanoid.Destroying:Connect(guarded(function()
			self:Unbind()
		end))
	)
	table.insert(
		self.lifecycle,
		character.Destroying:Connect(guarded(function()
			self:Unbind()
		end))
	)

	logger:debug("Bound", { rig = self.name, character = character.Name, phase = self.phase })
	return true
end

--[[
	Releases the current life completely: every track stopped and destroyed, every claim dropped,
	every lifecycle connection disconnected, every pending freeze invalidated by the generation bump.
	Safe to call on an already-unbound manager, and called automatically by Bind and by the
	character/Humanoid Destroying watches.

	Tracks are DESTROYED, not merely dropped. A track belongs to the Animator it was loaded from, so
	one from a previous life can never play again -- but it is still an Instance parented under that
	Animator, and a manager that only nils its reference leaves the engine holding it. Destroying is
	what makes a hundred respawns cost the same as one.
]]
function AnimationManager.Unbind(self: AnimationManagerInstance): ()
	if self.phase == "Unbound" and next(self.tracks) == nil then
		return
	end

	stopAll(self, "Stopped")
	disconnectLifecycle(self)

	for _, track in self.tracks do
		pcall(function()
			track:Destroy()
		end)
	end
	table.clear(self.tracks)

	self.character = nil
	self.humanoid = nil
	self.animator = nil
	self.phase = "Unbound"
	-- Invalidates every pending freeze restore and every in-flight lifecycle handler from this life.
	self.generation += 1
end

-- Permanent teardown -- for a bot pool retiring a rig, or a test releasing a manager. After this the
-- instance holds no connections at all, including the Heartbeat it may own, and must not be reused.
function AnimationManager.Destroy(self: AnimationManagerInstance): ()
	self:Unbind()
	local stepConnection = self.stepConnection
	if stepConnection then
		stepConnection:Disconnect()
		self.stepConnection = nil
	end
	table.clear(self.registry)
end

--[[
	A snapshot of what this manager is doing right now, for a dev overlay or a bug report. Read-only
	by construction (a fresh table every call) -- nothing here hands out a live reference to internal
	state, because a debug surface that can be written through stops being a debug surface.
]]
export type LayerDiagnostic = {
	Layer: string,
	Clip: string,
	Source: string,
	Looped: boolean,
	Playing: boolean,
	Frozen: boolean,
	Speed: number,
	Weight: number,
	ElapsedSeconds: number,
	Repairs: number,
}

export type Diagnostics = {
	Name: string,
	Phase: Phase,
	Generation: number,
	LoadedTracks: number,
	FrozenTracks: number,
	Layers: { LayerDiagnostic },
}

function AnimationManager.GetDiagnostics(self: AnimationManagerInstance): Diagnostics
	local layers: { LayerDiagnostic } = {}
	local now = os.clock()
	for layer, entry in self.active do
		table.insert(layers, {
			Layer = layer,
			Clip = entry.Clip,
			Source = entry.Source,
			Looped = entry.Looped,
			Playing = entry.Track.IsPlaying,
			Frozen = self.frozen[entry.Track] ~= nil,
			Speed = entry.DesiredSpeed,
			Weight = entry.Weight,
			ElapsedSeconds = now - entry.StartedAt,
			Repairs = entry.Repairs,
		})
	end
	table.sort(layers, function(a: LayerDiagnostic, b: LayerDiagnostic): boolean
		return a.Layer < b.Layer
	end)

	local loaded = 0
	for _ in self.tracks do
		loaded += 1
	end
	local frozen = 0
	for _ in self.frozen do
		frozen += 1
	end

	return {
		Name = self.name,
		Phase = self.phase,
		Generation = self.generation,
		LoadedTracks = loaded,
		FrozenTracks = frozen,
		Layers = layers,
	}
end

return AnimationManager
