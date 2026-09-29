--!strict
--[[
	ParkourAnimator.lua

	Owns: selecting the movement clip that goes with each parkour state -- driven by the state id, its
	variant (wall-run left vs. right, hop vs. vault), and live speed -- and pushing it onto this
	module's own claim on Shared/Animation/AnimationManager.lua's "Parkour" layer. Playing, crossfading,
	loop repair, freeze handling and death gating are ANIMATIONMANAGER'S job now, not this module's --
	see MIGRATION below.

	DRIVEN BY THE STATE MACHINE, NOT PARALLEL TO IT. The design was explicit: "make the animation
	system work together with the movement system rather than having parkour animations operate
	independently. Every parkour action should be able to select an appropriate animation based on the
	movement state, direction, speed, surface, and action being performed." So this module has no
	logic of its own about when anything happens -- ParkourController calls OnStateChanged on every
	transition and SetMotion every frame, and the clip is a pure function of what the state machine
	already decided. There is no second opinion here that could drift out of sync with the first.

	MIGRATION (this module used to hand-roll its own `tracks` dict, `getTrack`, `stopActive` and
	`protectedTrackCall`, and drive AnimationTrack:Play/Stop/AdjustSpeed directly -- exactly the
	four-modules-each-reimplementing-the-same-five-mechanics problem AnimationManager.lua's own header
	describes). Client/Defense/DefenseClient.lua was the first caller to migrate; this module follows
	its pattern: one manager constructed at module scope, clips registered once via RegisterMany, and
	every state transition expressed as a SetClaim on a dedicated "Parkour" layer/source pair rather
	than a manual Play/Stop pair. "At most one parkour track plays at a time" -- true before, and still
	true now -- is enforced structurally by that layer being this module's only claim on it, not by a
	local `activeTrack` variable this module has to maintain by hand. Client/FX/CombatAnimator.lua has
	NOT migrated yet (it still separately manages Walking/Running with its own Heartbeat evaluator), so
	this manager arbitrates only among its own claims for now -- the same known, pre-existing gap
	AnimationManager's own header describes, not something this module closes by itself. There is
	therefore no shared "Locomotion" layer here: "Parkour" coordinates with nothing outside this module
	yet, which is the honest state of the migration rather than an implied one.

	INTERRUPTIBLE BY CONSTRUCTION. A state change replaces this module's claim before the layer
	resolves the next one, which AnimationManager turns into a genuine crossfade -- so the framework
	can never leave a player locked in an animation ("animations should be interruptible when necessary
	so the player does not get locked into an animation when they need to transition into another
	movement action or combat"). There is no queue, no "wait for this to finish," and no clip whose
	length gates a transition.

	PRIORITY IS THE COMBAT BOUNDARY. Every clip here claims at Enum.AnimationPriority.Movement, while
	Client/FX/CombatAnimator.lua's swings/blocks/dashes load at Core (see that file's own note on why
	it had to match the default rig's own cycle). Movement sits BELOW Core, so a combat action always
	visually wins over a parkour clip without either module needing to coordinate with the other --
	which is the whole point: a player who attacks mid-slide sees the attack, and the slide continues
	to drive their body underneath it.

	A missing or placeholder animation id degrades to no clip playing, never an error -- the same
	tolerance Constants.Flight/Constants.Intro's own placeholder AnimationIds tables already rely on,
	which is what lets this ship before the real clips exist. AnimationManager.Register already treats
	an empty id as "not registered," so a SetClaim for an unauthored key is a safe, silent no-op here
	exactly as it is in DefenseClient.

	Does not own: any combat animation (CombatAnimator.lua), the decision to change state
	(StateMachine.lua), or any AnimationTrack mechanics (arbitration, crossfade, loop repair, freeze
	handling, the death gate -- all AnimationManager.lua's).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnimationManager = require(ReplicatedStorage.Shared.Animation.AnimationManager)
local EvadeConstants = require(ReplicatedStorage.Shared.Combat.EvadeConstants)
local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local ParkourMath = require(ReplicatedStorage.Shared.Parkour.ParkourMath)
local ParkourTypes = require(ReplicatedStorage.Shared.Parkour.ParkourTypes)

type MovementStateId = ParkourTypes.MovementStateId

local ANIMATION = ParkourConstants.Animation
local IDS = ParkourConstants.AnimationIds
-- The evade's optional directional clips live with the rest of the evade's tunables (EvadeConstants), not
-- in the parkour id table, and are registered under their own keys beside it.
local EVADE_IDS: { [string]: string } = {
	EvadeForward = EvadeConstants.AnimationIds.Forward,
	EvadeBack = EvadeConstants.AnimationIds.Back,
	EvadeLeft = EvadeConstants.AnimationIds.Left,
	EvadeRight = EvadeConstants.AnimationIds.Right,
}

local ParkourAnimator = {}

-- ONE manager for the local player's whole lifetime, bound/unbound per life -- the same shape
-- DefenseClient.lua's own manager uses. Clips registered once at module load under the SAME keys
-- STATE_CLIPS/VARIANT_CLIPS below already use, so resolveKey's output can be handed to SetClaim
-- directly with no second name mapping to keep in sync.
local manager = AnimationManager.new({ Name = "ParkourAnimator" })
manager:RegisterMany(IDS)
manager:RegisterMany(EVADE_IDS)

-- This module's own exclusive slot on the body and its one claim source. A dedicated layer rather
-- than sharing one with anything else -- see this file's header on why "Locomotion" does not exist
-- yet: CombatAnimator has not migrated, so there is nothing today for "Parkour" to arbitrate against
-- except itself.
local PARKOUR_LAYER = "Parkour"
local PARKOUR_SOURCE = "Parkour"

-- Client/Loading/AssetPreloader.lua's boot-time preload pass gets RAW CONTENT-ID STRINGS from this
-- module, not pre-built Animation instances -- deliberately unlike CombatAnimator/FlightAnimator/
-- EmoteAnimator's own GetPreloadInstances(), which hand back the very template instances they
-- already keep. AnimationManager pools its own template Instances internally and does not hand them
-- out (the same reason DefenseClient.GetPreloadInstances also returns raw ids), so ids are the only
-- thing this module has to preload with.
--
-- A raw id string is NOT a first-class manifest entry, and this function's caller is what makes it
-- one. ContentProvider:PreloadAsync reports Failure for a bare "rbxassetid://" string whatever the
-- asset is, so AssetPreloader wraps each id handed back here in a throwaway Animation instance
-- before the manifest ever reaches the engine -- see animationFor's header in that module for the
-- full account of how that bit once. Nothing here needs to change for that; ids remain the right
-- thing for this module to return, because the wrapping is the preloader's job, not the provider's.
-- Constants.Intro.AnimationIds is handled the same way for the same "no ongoing pool to be the
-- source of truth for" reason.
--
-- WHY IT MATTERS: without this, every parkour clip cold-loaded on FIRST USE -- i.e. mid-vault,
-- mid-wall-run, mid-ledge-grab. That is the worst possible moment to pay a fetch, and it was the
-- single largest gap in the manifest (twenty slots, eight ids the manifest never otherwise saw).
function ParkourAnimator.GetPreloadInstances(): { string }
	return manager:GetPreloadIds()
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
	Mantling = {
		Key = "Mantle",
		Looped = false,
		ScalesWithSpeed = false,
		FadeIn = PROFILES.Snap.FadeIn,
		FadeOut = PROFILES.Snap.FadeOut,
	},
	-- Also present in VARIANT_CLIPS below (as the "Charge" variant's own fallback -- i.e. no variant,
	-- which is what States/Leaping.lua publishes once its charge-up has committed to the flight). Same
	-- dual-entry shape as LedgeHanging/Landing below, for the same reason: a transition frame that
	-- reaches this resolver before Leaping.Update has cleared AnimationVariant back to nil still gets
	-- the flight clip instead of silently playing nothing.
	Leaping = {
		Key = "Leap",
		Looped = false,
		ScalesWithSpeed = false,
		FadeIn = PROFILES.Snap.FadeIn,
		FadeOut = PROFILES.Snap.FadeOut,
	},
	-- Also present in VARIANT_CLIPS below (as the "Hang" variant); both agree on looped/non-scaling.
	-- Kept here too, same as Landing's own dual entry, so a transition frame that reaches this
	-- resolver before LedgeHanging.Enter has published its variant still gets the hang loop instead
	-- of silently playing nothing for a frame.
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
--
-- A CLIP ENTRY MAY OVERRIDE THE STATE-LEVEL PLAYBACK FLAGS, per variant. Most states have one shape of
-- motion for every variant (a vault is one-shot whether it is a hop or a full vault-over), so a plain
-- string naming the clip key is enough and inherits the state's own Looped/ScalesWithSpeed/Fade
-- unchanged -- every existing entry below still works this way. States/WallRunning.lua is the reason
-- the override exists at all: since its kick phase was folded in as part of this same state (see that
-- file's header), ONE state now needs BOTH a looping, speed-scaled run clip (Left/Right) and a
-- one-shot, non-scaling kick clip (Kick*) -- two genuinely different shapes of motion that a single
-- Looped/ScalesWithSpeed pair per state cannot express. A variant entry given as a table instead of a
-- bare string may set any of Looped/ScalesWithSpeed/FadeIn/FadeOut; whichever it leaves nil falls back
-- to the state-level default exactly as a bare string does.
type VariantClipOverride = {
	Key: string,
	Looped: boolean?,
	ScalesWithSpeed: boolean?,
	FadeIn: number?,
	FadeOut: number?,
	-- While this variant's own asset is blank, play NOTHING rather than falling through to the state's
	-- shared clip. For a variant that is a different motion altogether, where the shared clip would be
	-- wrong rather than merely generic -- the evade glide, which must play no clip rather than a wrong one.
	NoFallback: boolean?,
}

local VARIANT_CLIPS: {
	[string]: {
		Looped: boolean,
		ScalesWithSpeed: boolean,
		FadeIn: number?,
		FadeOut: number?,
		Clips: { [string]: string | VariantClipOverride },
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
		-- Loops for as long as the run lasts, and scales with speed -- a wall-run at 34 should not play
		-- at the same cadence as one at 20, which is the case ParkourConstants.Animation is written
		-- about. The kick (Kick*) overrides both to one-shot/non-scaling: a departure is a single beat
		-- whose length is the control lock, not a cadence that should track speed -- see this map's own
		-- header on why a wall-run needs the override at all.
		--
		-- The kick clips are mirrored the same way the run itself is, and for the same reason: kicking
		-- off a wall on your left and kicking off on your right are opposite actions, and one shared
		-- clip plays half of them backwards. "KickNeutral" is a genuine third case rather than a
		-- fallback for missing data -- a wall square in front of or behind the character has no side
		-- (ParkourMath.WallSide returns 0 there), and playing either mirror for it reads as kicking off
		-- nothing. Named "Kick*" rather than reusing "Left"/"Right" so the loop and the one-shot kick
		-- can never be confused for one another by a reader of the variant string alone -- see
		-- States/WallRunning.lua's beginKick, which is the only thing that ever sets these.
		WallRunning = {
			Looped = true,
			ScalesWithSpeed = true,
			FadeIn = PROFILES.Settle.FadeIn,
			FadeOut = PROFILES.Settle.FadeOut,
			Clips = {
				Left = "WallRunLeft",
				Right = "WallRunRight",
				-- The catch: one-shot and non-scaling, like the kick and for the same reason -- it is a
				-- single beat of impact, not a cadence, and its horizontal speed is zero by construction
				-- so there would be nothing for the speed scaling to read. Unmirrored, unlike the run and
				-- the kick, because a head-on catch has no side to mirror: the character hits the wall
				-- square and faces into it (States/WallRunning's updateCatching commands exactly that).
				Catch = {
					Key = "WallCatch",
					Looped = false,
					ScalesWithSpeed = false,
					FadeIn = PROFILES.Snap.FadeIn,
					FadeOut = PROFILES.Snap.FadeOut,
				},
				KickLeft = {
					Key = "WallJumpLeft",
					Looped = false,
					ScalesWithSpeed = false,
					FadeIn = PROFILES.Snap.FadeIn,
					FadeOut = PROFILES.Snap.FadeOut,
				},
				KickRight = {
					Key = "WallJumpRight",
					Looped = false,
					ScalesWithSpeed = false,
					FadeIn = PROFILES.Snap.FadeIn,
					FadeOut = PROFILES.Snap.FadeOut,
				},
				KickNeutral = {
					Key = "WallJump",
					Looped = false,
					ScalesWithSpeed = false,
					FadeIn = PROFILES.Snap.FadeIn,
					FadeOut = PROFILES.Snap.FadeOut,
				},
			},
		},
		-- THE EVADE. No STATE_CLIPS entry and every variant NoFallback, on purpose: until a directional clip
		-- is authored (EvadeConstants.AnimationIds) the body keeps its current pose, which with the
		-- afterimage ghosts reads as a flash-step -- the training bot's look. States/Evading.Enter publishes
		-- the variant once, from the angle between travel and the held facing. Snap profile and one-shot:
		-- the informative frame of a dodge is its first.
		Evading = {
			Looped = false,
			ScalesWithSpeed = false,
			FadeIn = PROFILES.Snap.FadeIn,
			FadeOut = PROFILES.Snap.FadeOut,
			Clips = {
				Forward = { Key = "EvadeForward", NoFallback = true },
				Back = { Key = "EvadeBack", NoFallback = true },
				Left = { Key = "EvadeLeft", NoFallback = true },
				Right = { Key = "EvadeRight", NoFallback = true },
			},
		},
		-- Also present in STATE_CLIPS (as the no-variant fallback); both agree on one-shot, non-scaling.
		Landing = {
			Looped = false,
			ScalesWithSpeed = false,
			FadeIn = PROFILES.Ground.FadeIn,
			FadeOut = PROFILES.Ground.FadeOut,
			Clips = { Soft = "LandSoft", Medium = "LandSoft", Hard = "LandHard" },
		},
		-- Also present in STATE_CLIPS above (as the "Hang" variant's own fallback). States/LedgeHanging.lua
		-- publishes "Hang" at Enter and switches to "Shimmy" for as long as its Update is actually stepping
		-- the grab sideways (see that file's shimmy block), switching back to "Hang" the moment lateral
		-- intent drops below the threshold -- so this variant changes DURING a hang, not just at the
		-- transition into one, which is why ParkourController has to push it on more than the usual
		-- state-change edge (see that module's own note on lastAnimationVariant).
		LedgeHanging = {
			Looped = true,
			ScalesWithSpeed = false,
			FadeIn = PROFILES.Settle.FadeIn,
			FadeOut = PROFILES.Settle.FadeOut,
			Clips = { Hang = "LedgeHang", Shimmy = "LedgeShimmy" },
		},
		-- THREE PITCH BANDS, not the five body-relative quadrants this used to key on. The dash is
		-- aimed by the camera now and steered mid-flight, so "front/back/left/right relative to the
		-- chest" is not a thing a clip could honestly show: the body faces its own travel direction
		-- for the whole burst (States/Dashing.lua commands FaceDirection from live travel), which
		-- means every dash is, from the animation's point of view, a FORWARD one. What still varies,
		-- and what these three bands say, is whether it was aimed up, level or down.
		--
		-- THE ONLY VARIANT-DRIVEN STATE WITH NO STATE_CLIPS FALLBACK, and that absence survives the
		-- rewrite deliberately. Leaping/LedgeHanging/Landing each keep a dual entry so a transition
		-- frame arriving before the variant is published still plays something sensible. A dash has no
		-- sensible shared clip -- a rising launch and a dive are different motions, and playing one
		-- for the other would read worse than playing nothing -- and States/Dashing.lua publishes its
		-- band in Enter, before any frame can reach this resolver, so the gap those other three cover
		-- does not exist here.
		--
		-- Snap profile, one-shot, non-scaling: a dash is a single readable beat whose opening frame is
		-- the whole point. Non-scaling matters more than it used to -- commanded speed is now a SPRING
		-- (it winds up, overshoots, then bleeds off), so scaling playback to it would make the clip
		-- visibly stutter through the wind-up and drag through the settle.
		--
		-- Resolved ONCE, at Enter, off the launch angle -- steering does not re-trigger it. A dash
		-- banked from level into a climb keeps the clip it started with rather than cutting to another
		-- one mid-flight, which at these durations (0.4s total) would only ever read as a glitch.
		Dashing = {
			Looped = false,
			ScalesWithSpeed = false,
			FadeIn = PROFILES.Snap.FadeIn,
			FadeOut = PROFILES.Snap.FadeOut,
			Clips = { Up = "DashUp", Level = "DashLevel", Down = "DashDown" },
		},
		-- Also present in STATE_CLIPS above (as the no-variant fallback, played once the charge has
		-- committed to the flight). States/Leaping.lua publishes "Charge" for the brief wind-up
		-- (Leap.ChargeSeconds) before the arc is solved and flown, then clears AnimationVariant back to
		-- nil for the flight itself, which is what makes it fall through to STATE_CLIPS.Leaping's "Leap"
		-- clip without needing a redundant "Flight" entry here. Looped, unlike the flight clip: the
		-- charge's own duration is a tunable constant independent of whatever length the clip is
		-- authored at, so looping is what keeps the wind-up covered regardless of which finishes first.
		Leaping = {
			Looped = true,
			ScalesWithSpeed = false,
			FadeIn = PROFILES.Snap.FadeIn,
			FadeOut = PROFILES.Snap.FadeOut,
			Clips = { Charge = "LeapCharge" },
		},
	}

-- Last speed SetMotion was told about, so a clip that scales with speed can be STARTED at the right
-- cadence instead of playing its first frames at 1x and being corrected a frame later. That correction
-- is small and constant, which is exactly the kind of thing that reads as the animation not being
-- attached to the movement.
local lastPlanarSpeed = 0
-- Whether the CURRENTLY CLAIMED clip scales with speed, so SetMotion knows whether this frame's speed
-- feed means anything. Set by OnStateChanged, alongside the claim itself.
local currentScalesWithSpeed = false

-- Resolves which clip key a state should be playing, given its variant. Returns nil for a state with
-- no clip of its own, which is the common case (see STATE_CLIPS' own note).
-- Whether a clip key has a real asset id behind it. An id left blank is how this codebase says "not
-- authored yet" (see ParkourConstants.AnimationIds' own header), and the difference matters here rather
-- than at load time: a variant whose id is blank should fall THROUGH to the state's shared clip, where
-- one exists, instead of resolving to a key that will silently produce no track. That is what makes the
-- directional wall-jump pair safe to ship half-authored -- a missing WallJumpLeft plays the shared
-- WallJump, not nothing.
local function hasAsset(key: string): boolean
	local assetId = IDS[key] or EVADE_IDS[key]
	return assetId ~= nil and assetId ~= ""
end

local function resolveKey(stateId: MovementStateId, variant: string?): (string?, boolean, boolean, number, number)
	local variantEntry = VARIANT_CLIPS[stateId]
	if variantEntry and variant then
		local rawClip = variantEntry.Clips[variant]
		if rawClip then
			-- A bare string is sugar for "use every state-level default" -- see VARIANT_CLIPS' own
			-- header. Normalized to the same shape as an explicit override so the reads below don't
			-- need two branches.
			local clip: VariantClipOverride = if typeof(rawClip) == "string" then { Key = rawClip } else rawClip
			if hasAsset(clip.Key) then
				return clip.Key,
					if clip.Looped ~= nil then clip.Looped else variantEntry.Looped,
					if clip.ScalesWithSpeed ~= nil then clip.ScalesWithSpeed else variantEntry.ScalesWithSpeed,
					clip.FadeIn or variantEntry.FadeIn or ANIMATION.FadeInSeconds,
					clip.FadeOut or variantEntry.FadeOut or ANIMATION.FadeOutSeconds
			end
			if clip.NoFallback then
				return nil, false, false, ANIMATION.FadeInSeconds, ANIMATION.FadeOutSeconds
			end
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

-- Called on every state transition. Pushes this module's claim to match whatever the new state wants,
-- or clears it for a state with no clip. AnimationManager.SetClaim/resolveLayer own the crossfade
-- (Clear retires the outgoing entry with its OWN fade-out before the new claim starts -- see
-- AnimationManager.lua's `retire`/`start`), the same "outgoing clip leaves at its own pace" behavior
-- this module used to implement by hand via activeFadeOut.
function ParkourAnimator.OnStateChanged(_previous: MovementStateId, next: MovementStateId, variant: string?): ()
	local key, looped, scalesWithSpeed, fadeIn, fadeOut = resolveKey(next, variant)
	currentScalesWithSpeed = scalesWithSpeed
	if not key then
		manager:Clear(PARKOUR_LAYER, PARKOUR_SOURCE)
		return
	end
	-- Started AT the right playback speed rather than at 1x and corrected on the next frame. The
	-- correction was a visible hitch at the start of every slide and wall-run: the clip's opening frames
	-- played at the wrong cadence and then jumped, which reads as the animation being bolted on rather
	-- than driven by the movement. Passed as the claim's own Speed -- AnimationManager.start reads it
	-- straight into track:Play's own speed argument.
	local playbackSpeed = if scalesWithSpeed
		then ParkourMath.PlaybackSpeed(
			lastPlanarSpeed,
			ANIMATION.SpeedScaleReferenceSpeed,
			ANIMATION.MinPlaybackSpeed,
			ANIMATION.MaxPlaybackSpeed
		)
		else 1
	manager:SetClaim(PARKOUR_LAYER, PARKOUR_SOURCE, {
		Clip = key,
		Looped = looped,
		FadeIn = fadeIn,
		FadeOut = fadeOut,
		Priority = ANIMATION.Priority,
		Speed = playbackSpeed,
	})
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
	local speed = ParkourMath.PlaybackSpeed(
		planarSpeed,
		ANIMATION.SpeedScaleReferenceSpeed,
		ANIMATION.MinPlaybackSpeed,
		ANIMATION.MaxPlaybackSpeed
	)
	-- The one call that runs EVERY frame rather than once per transition. AnimationManager.SetSpeed is
	-- itself pcall-protected against a broken track (see its own header on why ParkourController.step's
	-- surrounding pcall makes that load-bearing rather than defensive habit), and no-ops cleanly when
	-- this layer currently has nothing active -- a stale speed feed left over from a transition frame
	-- cannot poke a track that no longer exists.
	manager:SetSpeed(PARKOUR_LAYER, speed)
end

-- Rebuilds against a fresh character's Animator (AnimationManager.Bind resolves it internally --
-- Client/AnimatorUtil.lua's lookup is no longer this module's own concern). Bind() ends the previous
-- life's claims/tracks itself (Unbind() runs first thing inside it), so nothing here needs a separate
-- reset beyond this module's own local speed-scaling flag.
function ParkourAnimator.BindCharacter(character: Model): ()
	currentScalesWithSpeed = false
	manager:Bind(character)
end

-- Hard stop, for the framework being switched off mid-life. Distinct from Unbind: the character (and
-- its Animator) are still alive, only this module's own claim needs to go, so this drops the layer
-- rather than tearing down the whole manager.
function ParkourAnimator.Reset(): ()
	manager:ClearLayer(PARKOUR_LAYER)
	currentScalesWithSpeed = false
end

-- Hard stop for character teardown, distinct from Reset above: the character (and its Animator) are
-- going away too, so every track this manager holds is stopped and destroyed, not just this layer's.
function ParkourAnimator.Unbind(): ()
	manager:Unbind()
	currentScalesWithSpeed = false
end

return ParkourAnimator
