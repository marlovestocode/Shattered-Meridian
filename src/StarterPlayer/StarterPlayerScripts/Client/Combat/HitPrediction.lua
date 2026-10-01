--!strict
--[[
	HitPrediction.lua

	Owns: the attacker's PREDICTED hit -- the moment the local player's own swing volume overlaps a
	target on their own screen, the impact plays (CombatFeedbackClient.PresentPredictedHit: thud, flash,
	exchange freeze, shake) and the target flinches (HitFlinchPose.Predict), without waiting for the
	server. AttackConstants.Presentation.HitPrediction's header has the whole contract; in short:

	  * WHY. A hit reached the attacker a full round trip after the server resolved it, plus up to
	    DefenseConstants.Parry.RewindMaxSeconds of lag-rewind hold. On a live server the fist landed on
	    screen and the hit arrived a beat later, every time. Studio (zero ping) never shows it.
	  * NEVER A HIT DECISION. Nothing here is sent anywhere. The server's engine decides every contact, and
	    its verdict still arrives and still drives damage, stun, knockback and the numbers. When it
	    disagrees it plays in full over the prediction -- see consumePrediction in CombatFeedbackClient.
	  * CONSERVATIVE. Only a volume the client can reproduce exactly (AttackTypes.ContactVolume -- any shape
	    on any anchor, at a flat size) is predicted, and never against a body that is visibly guarding or
	    evading -- the two answers that would turn a predicted hit into a reversal. The volume is rebuilt
	    on this client's own rig with the engine's own pieces (HitboxAnchor for the part, HitboxGeometry
	    for the test), so the prediction and the engine cannot disagree about what the shape IS -- only
	    about where the bodies are.

	ZERO IDLE COST: the Heartbeat connection exists only while one of this player's swings is winding up
	or active.

	Does not own: the swing itself (AttackInputClient), the impact presentation (CombatFeedbackClient),
	the flinch (HitFlinchPose), or who counts as a target (CombatTargets).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local AttackConstants = require(ReplicatedStorage.Shared.Attack.AttackConstants)
local AttackTypes = require(ReplicatedStorage.Shared.Attack.AttackTypes)
local AttributeConstants = require(ReplicatedStorage.Shared.AttributeConstants)
local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local DefenseConstants = require(ReplicatedStorage.Shared.Defense.DefenseConstants)
local HitboxAnchor = require(ReplicatedStorage.Shared.HitboxEngine.HitboxAnchor)
local HitboxGeometry = require(ReplicatedStorage.Shared.HitboxEngine.HitboxGeometry)
local Logger = require(ReplicatedStorage.Shared.Logger)
local Trove = require(ReplicatedStorage.Shared.Trove)

local AttackInputClient = require(script.Parent.AttackInputClient)
local CombatFeedbackClient = require(script.Parent.CombatFeedbackClient)
local CombatTargets = require(script.Parent.CombatTargets)
local HitFlinchPose = require(script.Parent.Parent.FX.HitFlinchPose)

local logger = Logger.scope("HitPrediction")

local HitPrediction = {}

local CONFIG = AttackConstants.Presentation.HitPrediction

type PendingSwing = {
	MoveId: string,
	Volume: AttackTypes.ContactVolume,
	-- The rig part the volume is anchored on, resolved once the window opens (HitboxAnchor).
	Anchor: BasePart?,
	OpensAt: number,
	ClosesAt: number,
	-- Targets already predicted for this swing: one impact per body per swing, as the engine allows.
	Struck: { [Model]: boolean },
}

local pending: PendingSwing? = nil
local heartbeat: RBXScriptConnection? = nil
local started = false
local trove = Trove.New()

-- Pure pieces ----------------------------------------------------------------------------------------

-- Whether a point, given in the space of the part the box is anchored on (the attacker's ROOT for a
-- root-anchored box), is inside `box` grown by the body padding.
function HitPrediction.Contains(box: AttackTypes.ContactBox, pointInRootSpace: Vector3): boolean
	local local_ = box.Offset:PointToObjectSpace(pointInRootSpace)
	local half = box.Size / 2
	return math.abs(local_.X) <= half.X + CONFIG.PadStuds
		and math.abs(local_.Y) <= half.Y + CONFIG.PadHeightStuds
		and math.abs(local_.Z) <= half.Z + CONFIG.PadStuds
end

-- Heights above and below a target's root that a non-box volume is probed at. A box is grown by the body's
-- half-height instead (PadHeightStuds); the other shapes have one uniform margin, so the body's height is
-- covered by testing its upper and lower torso as well as its centre.
local HEIGHT_PROBES = { 0, 1.5, -1.5 }

-- Whether `volume`, anchored on `anchor`, contains a target whose root is at `rootPosition`. A Box keeps the
-- box test above (and its per-axis padding); every other shape is the engine's own ContainsPoint.
function HitPrediction.VolumeContains(
	volume: AttackTypes.ContactVolume,
	anchor: BasePart,
	rootPosition: Vector3
): boolean
	local anchorFrame = anchor.CFrame
	if volume.Shape == "Box" then
		local dimensions = volume.Dimensions
		local size = if volume.SizeFromAttachmentPart
			then anchor.Size * (volume.SizeMultiplier or 1)
			else Vector3.new(dimensions.Width, dimensions.Height, dimensions.Length)
		return HitPrediction.Contains(
			{ Size = size, Offset = volume.Offset },
			anchorFrame:PointToObjectSpace(rootPosition)
		)
	end
	local pose = anchorFrame * volume.Offset
	for _, lift in HEIGHT_PROBES do
		local point = pose:PointToObjectSpace(rootPosition + Vector3.new(0, lift, 0))
		if HitboxGeometry.ContainsPoint(volume.Shape, volume.Dimensions, point, CONFIG.PadStuds) then
			return true
		end
	end
	return false
end

-- The defence states in which a hit is likely to be answered. Staggered, GuardBroken and ParryRecovery
-- (a whiffed parry) are deliberately absent: a body in those is exactly the one that gets hit.
local GUARDING_STATES: { [string]: boolean } = {
	Raising = true,
	ParryWindow = true,
	Blocking = true,
}

-- Whether a body shows the answers that most often turn a hit into something else -- its guard up (or
-- rising, or parrying), or an evade under way. Read off the Attributes every client already has.
function HitPrediction.LooksDefended(humanoid: Humanoid): boolean
	local state = humanoid:GetAttribute(DefenseConstants.DefenseStateAttribute)
	if typeof(state) == "string" and GUARDING_STATES[state] then
		return true
	end
	return humanoid:GetAttribute(AttributeConstants.ParkourState) == "Evade"
end

-- The loop -------------------------------------------------------------------------------------------

local function stop(): ()
	pending = nil
	if heartbeat then
		heartbeat:Disconnect()
		heartbeat = nil
	end
end

local function step(): ()
	local swing = pending
	if not swing then
		stop()
		return
	end
	local now = os.clock()
	if now > swing.ClosesAt then
		stop()
		return
	end
	if now < swing.OpensAt then
		return
	end
	local character = Players.LocalPlayer.Character
	local root = if character then CharacterUtil.RootOf(character) else nil
	if not character or not root then
		stop()
		return
	end
	local anchor = swing.Anchor
	if anchor == nil or anchor.Parent == nil then
		-- Resolved at the window, not the throw: a weapon's blade may be welded in during the windup.
		anchor = HitboxAnchor.Resolve(character, root, swing.Volume.AttachmentPart)
		swing.Anchor = anchor
	end
	for _, target in CombatTargets.All(character) do
		local model = target.Model
		if swing.Struck[model] then
			continue
		end
		local humanoid = CharacterUtil.LiveHumanoidOf(model)
		if not humanoid or HitPrediction.LooksDefended(humanoid) then
			continue
		end
		if not HitPrediction.VolumeContains(swing.Volume, anchor, target.Root.Position) then
			continue
		end
		swing.Struck[model] = true
		-- The contact point the server would report sits on the target, not the attacker: its root is the
		-- honest stand-in.
		if CombatFeedbackClient.PresentPredictedHit(character, model, target.Root.Position, swing.MoveId) then
			HitFlinchPose.Predict(humanoid)
		end
	end
end

local function onAttackStarted(payload: AttackTypes.AttackStartedPayload): ()
	local volume = payload.ContactVolume
	if not CONFIG.Enabled or volume == nil then
		-- A newer swing that cannot be predicted still replaces the old one's window.
		stop()
		return
	end
	local now = os.clock()
	local opensAt = now + payload.WindupSeconds
	pending = {
		MoveId = payload.MoveId,
		Volume = volume,
		Anchor = nil,
		OpensAt = opensAt,
		ClosesAt = opensAt + payload.ActiveSeconds,
		Struck = {},
	}
	if not heartbeat then
		heartbeat = RunService.Heartbeat:Connect(step)
	end
end

-- Lifecycle ------------------------------------------------------------------------------------------

function HitPrediction.Start(): ()
	if started then
		return
	end
	started = true
	trove:Add(AttackInputClient.OnAttackStarted(onAttackStarted))
	-- A swing the server (or this client) cut short hits nothing more.
	trove:Add(AttackInputClient.OnSwingCancelled(function()
		stop()
	end))
	trove:Add(stop)
	logger:info("HitPrediction started")
end

function HitPrediction.Stop(): ()
	trove:Clean()
	started = false
end

return HitPrediction
