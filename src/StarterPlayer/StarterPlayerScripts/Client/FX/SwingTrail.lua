--!strict
--[[
	SwingTrail.lua

	Owns: drawing the swing trail -- a Trail on the limb (or weapon) that actually throws each of the LOCAL
	PLAYER'S swings, lit for the swing's ACTIVE window (the window the hitbox is live for, plus a short lead
	and tail), so the line reads as "this is where the hit could land".

	WHICH LIMB is Shared/Combat/SwingTrailAnchor.lua's answer, and it is data: a weapon's slot-folder
	Attribute, then AttackConstants.Presentation.SwingTrail.Anchors per stage, then the default. The bare-
	hands string is right, left, right because its clips are; an armed swing rides the weapon. Read that
	module's header before changing what a swing rides -- this one only draws.

	FOLLOWS THE LIMB BY CONSTRUCTION. The Trail's two Attachments are parented to the limb part itself (or
	the blade), around its tip, so the engine moves them with every animated frame of the swing -- nothing
	here samples or copies a pose. A rig's grip Attachment marks the tip when there is one.

	ONE TRAIL PER ANCHOR, KEPT FOR THE LIFE OF THE CHARACTER. Built the first time a swing needs it and
	reused after; a new swing on the OTHER hand never clears this one, so a right-left-right string leaves
	each punch's streak to fade out on its own Lifetime instead of cutting it when the next punch starts
	(the old single pooled trail Clear()ed the last streak on every press). A weapon's trail is rebuilt when
	the part it resolved to changes (a swap, a re-draw), and every trail goes with BindCharacter.

	THE WINDOW IS READ OFF THE SWING'S OWN CLIP, NOT A CLOCK. The payload's windup and active seconds say
	where the strike is in WALL time at the clip's playback speed; times that speed they are where it is in
	the CLIP. Each Heartbeat compares that span with the clip's real playhead (AttackInputClient.
	GetSwingPlayback), so the trail lights on the frames the arm is actually striking on -- whatever started,
	restarted, froze (hit-stop), offset or re-timed the clip. A wall-clock schedule from the press drifted off
	the punch as soon as any of those happened: on every string after the first, the streak drew after the
	arm had already come back. A swing with no clip (a blank id, one that failed to load) falls back to the
	wall clock from the press, which is all there is to sync to. Polled rather than task.delay'd (the shape
	Client/Combat/SwingLunge uses): a polled window is cancelled by dropping a reference. Not a render step,
	so not a FrameOrder slot -- it only flips Enabled; the engine does the drawing.

	CANCELS (AttackInputClient.OnSwingCancelled). "Interrupted" stops the trail where it is and lets the drawn
	part fade. "Unconfirmed" -- a prediction the server never threw -- clears it, since that swing never
	happened. "Feint" flares the trail in SwingTrail.FeintColor for FeintPulseSeconds as the arm pulls back:
	the feint cue, readable in hindsight.

	A MOVE MAY RECOLOUR OR REMOVE ITS TRAIL: the Active cue's TrailColor (Shared/Combat/
	MovePresentationTypes.lua, resolved by Client/FX/MovePresentation.lua) replaces SwingTrail.Color for that
	swing, and None draws no trail at all.

	LOCAL-PLAYER-ONLY. Attack_Started is a FireClient to the thrower alone, so there is no signal for another
	character's swing; showing one would need that layer to broadcast. See AttackConstants.Presentation.
	SwingTrail's own header.

	Replaces Client/FX/AttackTrail.lua (deleted 2026-10-27), which put the bare-hands string on the left arm,
	right arm and left LEG -- two punches in three drew on a limb that was not moving.

	Does not own: when a swing starts or how long it runs (AttackInputClient), the swing's animation
	(CombatAnimator / AttackInputClient) or sound (CombatAudio). Presentation only; nothing here crosses the
	network or affects an outcome.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local AttackConstants = require(ReplicatedStorage.Shared.Attack.AttackConstants)
local AttackTypes = require(ReplicatedStorage.Shared.Attack.AttackTypes)
local Logger = require(ReplicatedStorage.Shared.Logger)
local MovePresentationTypes = require(ReplicatedStorage.Shared.Combat.MovePresentationTypes)
local SwingTrailAnchor = require(ReplicatedStorage.Shared.Combat.SwingTrailAnchor)
local Trove = require(ReplicatedStorage.Shared.Trove)

local AttackInputClient = require(script.Parent.Parent.Combat.AttackInputClient)
local SwingLunge = require(script.Parent.Parent.Combat.SwingLunge)
local MovePresentation = require(script.Parent.MovePresentation)

type AttackStartedPayload = AttackTypes.AttackStartedPayload
type Anchor = SwingTrailAnchor.Anchor
type Target = SwingTrailAnchor.Target

local logger = Logger.scope("SwingTrail")

local TUNING = AttackConstants.Presentation.SwingTrail

local SwingTrail = {}

-- One anchor's trail. Owned is the Attachment pair this module made (empty when the trail uses a pair the
-- weapon author placed, which is never this module's to destroy).
type TrailRig = {
	Trail: Trail,
	Part: BasePart,
	Owned: { Attachment },
}

-- Clip is the swing clip this window is read off, with ClipFrom/ClipTo the span of it the trail lights for
-- (clip seconds); nil reads StartsAt/EndsAt off the wall clock instead (no clip, and the feint's flare).
type Window = {
	Rig: TrailRig,
	MoveId: string,
	Clip: string?,
	ClipFrom: number,
	ClipTo: number,
	StartsAt: number,
	EndsAt: number,
	Lit: boolean,
}

local rigs: { [Anchor]: TrailRig } = {}
local live: Window? = nil
-- The trail of the most recent swing, for a feint's flare after its window has already closed.
local lastRig: TrailRig? = nil
local character: Model? = nil

local lifetime: Trove.TroveInstance? = nil

-- Destroyed under pcall: a weapon trail goes with its Tool when the weapon is sheathed, and destroying it
-- again is harmless but a locked Parent is not worth a thrown error on the way out.
local function destroyRig(rig: TrailRig): ()
	pcall(function()
		rig.Trail:Destroy()
	end)
	for _, attachment in rig.Owned do
		pcall(function()
			attachment:Destroy()
		end)
	end
end

local function destroyAll(): ()
	live = nil
	lastRig = nil
	for _, rig in rigs do
		destroyRig(rig)
	end
	table.clear(rigs)
end

-- Whether `rig` is still on the part `target` resolved to, with the same Attachments, and alive.
local function rigMatches(rig: TrailRig, target: Target): boolean
	if rig.Part ~= target.Part or rig.Trail.Parent ~= target.Part then
		return false
	end
	if target.Near then
		return rig.Trail.Attachment0 == target.Near and rig.Trail.Attachment1 == target.Far
	end
	local near, far = rig.Owned[1], rig.Owned[2]
	return near ~= nil and far ~= nil and near.Parent == target.Part and far.Parent == target.Part
end

local function buildRig(target: Target): TrailRig
	local owned: { Attachment } = {}
	local near, far = target.Near, target.Far
	if not near or not far then
		local madeNear = Instance.new("Attachment")
		madeNear.Name = "SwingTrailNear"
		madeNear.CFrame = target.NearOffset
		madeNear.Parent = target.Part
		local madeFar = Instance.new("Attachment")
		madeFar.Name = "SwingTrailFar"
		madeFar.CFrame = target.FarOffset
		madeFar.Parent = target.Part
		near, far = madeNear, madeFar
		owned = { madeNear, madeFar }
	end

	local trail = Instance.new("Trail")
	trail.Name = "SwingTrail"
	trail.Attachment0 = near
	trail.Attachment1 = far
	trail.Color = TUNING.Color
	trail.Transparency = TUNING.Transparency
	-- No Width: a Trail has none. Its thickness is the Attachment pair's separation (AttackConstants).
	trail.WidthScale = TUNING.WidthScale
	trail.Lifetime = TUNING.LifetimeSeconds
	trail.LightEmission = TUNING.LightEmission
	trail.LightInfluence = TUNING.LightInfluence
	trail.Brightness = TUNING.Brightness
	trail.FaceCamera = TUNING.FaceCamera
	trail.Enabled = false
	trail.Parent = target.Part
	return { Trail = trail, Part = target.Part, Owned = owned }
end

-- The trail for `target`, reused when it still fits, rebuilt when its part changed or went away. Built
-- here, at the swing's start, and lit only after the windup: the pair has settled on its part by the time
-- it draws, so no segment streaks in from wherever it was made.
local function rigFor(target: Target): TrailRig
	local rig = rigs[target.Anchor]
	if rig and rigMatches(rig, target) then
		return rig
	end
	if rig then
		destroyRig(rig)
	end
	local built = buildRig(target)
	rigs[target.Anchor] = built
	return built
end

-- Ends the live window. Disabled, not cleared, so what is already drawn fades on Trail.Lifetime; `clear`
-- removes it too, for a swing that never happened.
local function endLive(clear: boolean): ()
	local current = live
	live = nil
	if not current then
		return
	end
	pcall(function()
		current.Rig.Trail.Enabled = false
		if clear then
			current.Rig.Trail:Clear()
		end
	end)
end

local function onAttackStarted(payload: AttackStartedPayload): ()
	if not TUNING.Enabled then
		return
	end
	-- A new swing always retires the last one's window: a string never draws two live trails at once.
	endLive(false)

	local currentCharacter = character
	if not currentCharacter then
		return
	end

	local cue = MovePresentation.CueFor(payload.MoveId, "Active")
	local authoredColor = if cue then cue.TrailColor else nil
	if authoredColor == MovePresentationTypes.None then
		return
	end

	local anchor = SwingTrailAnchor.ForSwing(payload.MoveId, payload.Kind, payload.StageIndex, payload.WeaponId)
	local target = SwingTrailAnchor.Target(currentCharacter, anchor)
	if not target then
		-- A rig missing the limb (mid-respawn). Cosmetic, and on a hot path: silent.
		return
	end

	local rig = rigFor(target)
	local color = MovePresentation.Color(authoredColor, nil)
	rig.Trail.Color = if color then ColorSequence.new(color) else TUNING.Color
	lastRig = rig

	-- The hit window plus a lead into it and a tail after it -- the trail traces the swing, the hitbox stays
	-- exactly the window. In wall seconds from the swing's start; times the playback speed, in clip seconds.
	local from = SwingLunge.DelayFor(payload.WindupSeconds, -TUNING.LeadSeconds)
	local to = payload.WindupSeconds + payload.ActiveSeconds + TUNING.TailSeconds
	local speed = if typeof(payload.PlaybackSpeed) == "number" and payload.PlaybackSpeed > 0
		then payload.PlaybackSpeed
		else 1
	-- AttackInputClient starts the clip before it tells its listeners, so a swing with a clip already holds
	-- the layer here.
	local position, clip = AttackInputClient.GetSwingPlayback()
	local clipDriven = position ~= nil and payload.AnimationId ~= "" and clip == payload.AnimationId
	local now = os.clock()
	live = {
		Rig = rig,
		MoveId = payload.MoveId,
		Clip = if clipDriven then clip else nil,
		ClipFrom = from * speed,
		ClipTo = to * speed,
		StartsAt = now + from,
		EndsAt = now + to,
		Lit = false,
	}
end

local function onSwingCancelled(reason: AttackInputClient.SwingCancelReason): ()
	if reason ~= "Feint" then
		endLive(reason == "Unconfirmed")
		return
	end
	endLive(false)
	local rig = lastRig
	if not TUNING.Enabled or not rig or not rig.Trail.Parent then
		return
	end
	rig.Trail.Color = TUNING.FeintColor
	local now = os.clock()
	live = {
		Rig = rig,
		MoveId = "Feint",
		Clip = nil,
		ClipFrom = 0,
		ClipTo = 0,
		StartsAt = now,
		EndsAt = now + TUNING.FeintPulseSeconds,
		Lit = false,
	}
end

local function onHeartbeat(): ()
	local current = live
	if not current then
		return
	end
	local trail = current.Rig.Trail
	if not trail.Parent then
		-- Its part went mid-swing (a sheathe or a swap); the next swing rebuilds it.
		live = nil
		return
	end
	local lit: boolean, over: boolean
	local clip = current.Clip
	if clip then
		local position, playing = AttackInputClient.GetSwingPlayback()
		if position == nil or playing ~= clip then
			-- The clip ended, was cut, or another one took the layer: this swing is over.
			lit, over = false, true
		else
			lit, over = position >= current.ClipFrom, position >= current.ClipTo
		end
	else
		local now = os.clock()
		lit, over = now >= current.StartsAt, now >= current.EndsAt
	end

	if over then
		trail.Enabled = false
		live = nil
		return
	end
	if lit and not current.Lit then
		current.Lit = true
		-- Nothing of this trail's last swing is left to fade by now (one Lifetime is far shorter than a
		-- swing), and clearing on the lighting frame guarantees the first segment starts at the strike.
		trail:Clear()
		if TUNING.Debug then
			local position = AttackInputClient.GetSwingPlayback()
			logger:info("Trail lit", {
				moveId = current.MoveId,
				clipDriven = clip ~= nil,
				playhead = position,
				clipFrom = current.ClipFrom,
				clipTo = current.ClipTo,
			})
		end
	end
	if trail.Enabled ~= lit then
		trail.Enabled = lit
	end
end

function SwingTrail.BindCharacter(newCharacter: Model): ()
	destroyAll()
	character = newCharacter
end

function SwingTrail.Start(): ()
	if lifetime then
		return
	end
	local trove = Trove.New()
	lifetime = trove
	trove:Add(AttackInputClient.OnAttackStarted(onAttackStarted))
	trove:Add(AttackInputClient.OnSwingCancelled(onSwingCancelled))
	trove:Connect(RunService.Heartbeat, onHeartbeat)
	logger:debug("SwingTrail started", { enabled = TUNING.Enabled })
end

function SwingTrail.Stop(): ()
	local trove = lifetime
	if not trove then
		return
	end
	lifetime = nil
	trove:Clean()
	destroyAll()
	character = nil
end

return SwingTrail
