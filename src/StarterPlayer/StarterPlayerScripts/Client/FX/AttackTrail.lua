--!strict
--[[
	AttackTrail.lua

	Owns: the swing trail -- a short Roblox Trail that traces the attacking limb through the ACTIVE
	window of the LOCAL PLAYER'S OWN swing (the window the hitbox is actually live for, not the whole
	animation), so the line reads as "this is where the hit could land" rather than as decoration.

	LOCAL-PLAYER-ONLY, ON PURPOSE, THE SAME AS Client/FX/CombatAudio.lua's PlaySwing. Attack_Started
	(Client/Combat/AttackInputClient.OnAttackStarted) is a FireClient, not a FireAllClients --
	Server/Combat/Attack/AttackRequestSystem.lua only ever tells the thrower their own swing was
	accepted, so this module has no signal at all for another character's swing today. That is a real
	limitation (a PvP read on an opponent's incoming swing is arguably more valuable than seeing your
	own), not an oversight in this file -- closing it needs the attack layer to broadcast, which is
	that layer's call, not a client-side FX module's. See AttackConstants.Presentation.SwingTrail's own
	header for the same note where the tuning lives.

	SCHEDULED AGAINST THE SWING'S OWN WINDUP AND ACTIVE SECONDS, on the identical Heartbeat-driven
	`window` shape Client/Combat/SwingLunge.lua already uses for the same reason: a scheduled
	task.delay thread is one a respawn or a cancelled swing has no way to reach and cancel, where a
	polled window is cleared by just dropping the reference. Enabled turns on just before the windup
	ends and off just after ActiveSeconds does (SwingTrail.LeadSeconds/TailSeconds -- the arm's
	acceleration into the strike and its follow-through; the window alone is a ~0.2s flicker) -- not
	tied to the animation's own total length, which includes recovery the trail has no reason to still
	be drawing through.

	RESOLVES ITS OWN ATTACHMENT POINT PER SWING, from the AttackStartedPayload alone -- no
	subscription to Weapon_InventoryChanged of its own, and no cached "current weapon" to go stale.
	Fists (WeaponRoster.FISTS_ID) means no Tool exists at all (WeaponVisualSystem never builds one for
	it -- see that module's own header), so the trail rides the striking limb itself, chosen by the
	payload's Kind and StageIndex (FistLimbFor): left hand, right hand, left foot through the Basic
	string (THIS IS AN R6 GAME -- there is no separate hand or foot part; the end of the limb is). Any
	other weapon id means a real Tool named WeaponConstants.Visual.ToolName should exist on the
	character, and the trail rides its Handle. A swing whose Tool has not replicated yet (a draw and an
	attack pressed in the same instant) simply gets no trail for that one swing rather than erroring --
	cosmetic-only, exactly like WeaponVisualSystem's own equip-failure path.

	ONE TRAIL AND ONE ATTACHMENT PAIR, BUILT ONCE AND REPARENTED PER SWING (combat performance audit
	F4). This used to build all three fresh on every swing, on the theory that a swing is rare enough
	not to matter -- but a mashed Basic string is several a second for the whole fight, and each one was
	three Instance.new and three Destroy. Now a swing reparents the same three onto its anchor part,
	after disabling the trail and clearing its drawn segments so nothing streaks across from the last
	anchor. The one hazard reuse brings -- the anchor was a Tool that got sheathed, and Roblox destroyed
	the pooled Instances with it -- is caught at the reparent (a destroyed Instance's Parent is locked,
	so the assignment throws) and answered by building a fresh set, so a swap or a respawn still cannot
	leave a trail on a part that no longer exists.

	A CANCELLED SWING TAKES ITS TRAIL WITH IT (AttackInputClient.OnSwingCancelled): a swing cut in its
	windup never reaches the strike, so its scheduled trail is dropped. A FEINT instead flares the trail
	briefly in AttackConstants.Presentation.SwingTrail.FeintColor as the arm pulls back -- the feint
	cue, readable in hindsight.

	Does not own: WHEN a swing starts or how long it runs (AttackInputClient/AttackStartedPayload
	decide that; this module only reacts), what the swing looks like otherwise (Client/FX/
	CombatAnimator.lua), or its sound (Client/FX/CombatAudio.lua). Purely local presentation; nothing
	here crosses the network or affects an outcome.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local AttackConstants = require(ReplicatedStorage.Shared.Attack.AttackConstants)
local AttackTypes = require(ReplicatedStorage.Shared.Attack.AttackTypes)
local Logger = require(ReplicatedStorage.Shared.Logger)
local WeaponConstants = require(ReplicatedStorage.Shared.Combat.WeaponConstants)
local WeaponRoster = require(ReplicatedStorage.Shared.Combat.WeaponRoster)

local AttackInputClient = require(script.Parent.Parent.Combat.AttackInputClient)
local SwingLunge = require(script.Parent.Parent.Combat.SwingLunge)

type AttackStartedPayload = AttackTypes.AttackStartedPayload

local logger = Logger.scope("AttackTrail")

local AttackTrail = {}

local TUNING = AttackConstants.Presentation.SwingTrail

type Window = {
	startsAt: number,
	durationSeconds: number,
}

local window: Window? = nil
local trail: Trail? = nil
local attachment0: Attachment? = nil
local attachment1: Attachment? = nil

local character: Model? = nil

local started = false
local startedDisconnect: (() -> ())? = nil
local cancelledDisconnect: (() -> ())? = nil
local heartbeatConnection: RBXScriptConnection? = nil

-- Takes the pooled trail off whatever it was riding, without destroying it: disabled, its drawn
-- segments cleared, and unparented so it holds no reference into a rig or Tool that may be about to
-- go. Safe with nothing built, and on a set Roblox already destroyed along with its anchor (the pcall).
local function releaseTrail(): ()
	window = nil
	local currentTrail = trail
	if currentTrail then
		pcall(function()
			currentTrail.Enabled = false
			currentTrail:Clear()
			currentTrail.Parent = nil
		end)
	end
	local near, far = attachment0, attachment1
	if near then
		pcall(function()
			near.Parent = nil
		end)
	end
	if far then
		pcall(function()
			far.Parent = nil
		end)
	end
end

local function destroyTrail(): ()
	releaseTrail()
	if trail then
		trail:Destroy()
	end
	if attachment0 then
		attachment0:Destroy()
	end
	if attachment1 then
		attachment1:Destroy()
	end
	trail = nil
	attachment0 = nil
	attachment1 = nil
end

-- Parents `instance` under `parent`, reporting false when it cannot be -- which, for an Instance this
-- module owns, means Roblox destroyed it with a previous anchor.
local function tryParent(instance: Instance, parent: Instance): boolean
	return (pcall(function()
		instance.Parent = parent
	end))
end

-- The pooled set, moved onto `part` at the given offsets -- or a fresh set when the pooled one was
-- destroyed along with its last anchor (or never built). Left disabled, cleared and pale.
local function acquire(part: BasePart, offsetNear: CFrame, offsetFar: CFrame): ()
	releaseTrail()
	local pooledTrail, pooled0, pooled1 = trail, attachment0, attachment1
	local reused = pooledTrail ~= nil
		and pooled0 ~= nil
		and pooled1 ~= nil
		and tryParent(pooled0, part)
		and tryParent(pooled1, part)
		and tryParent(pooledTrail, part)
	if not reused then
		-- The whole old set, not just the piece that failed: a reuse that got partway (one Attachment
		-- reparented before another refused) would otherwise leave that one behind on the new anchor.
		for _, stale in { pooledTrail, pooled0, pooled1 } :: { Instance? } do
			if stale then
				pcall(function()
					stale:Destroy()
				end)
			end
		end
		local a0 = Instance.new("Attachment")
		a0.Name = "AttackTrailNear"
		a0.Parent = part
		local a1 = Instance.new("Attachment")
		a1.Name = "AttackTrailFar"
		a1.Parent = part
		local newTrail = Instance.new("Trail")
		newTrail.Attachment0 = a0
		newTrail.Attachment1 = a1
		newTrail.Transparency = TUNING.Transparency
		-- No Width: a Trail has none. Its thickness is the Attachment pair's separation -- see
		-- AttackConstants.Presentation.SwingTrail.
		newTrail.WidthScale = TUNING.WidthScale
		newTrail.Lifetime = TUNING.LifetimeSeconds
		newTrail.LightEmission = TUNING.LightEmission
		newTrail.LightInfluence = TUNING.LightInfluence
		newTrail.Brightness = TUNING.Brightness
		newTrail.FaceCamera = TUNING.FaceCamera
		newTrail.Enabled = false
		newTrail.Parent = part
		trail = newTrail
		attachment0 = a0
		attachment1 = a1
	end
	if attachment0 then
		attachment0.CFrame = offsetNear
	end
	if attachment1 then
		attachment1.CFrame = offsetFar
	end
	if trail then
		trail.Color = TUNING.Color
	end
end

-- The part this swing's trail should ride, and the pair of local-space offsets (in studs, ALONG THAT
-- PART'S OWN AXIS) marking the near/far end -- Y for an arm (its long axis is vertical, shoulder to
-- fist), Z for a weapon Handle (-Z is forward down the blade, the same convention Shared/Combat/
-- WeaponRoster.lua's own header states for a weapon's grip). Returns nil for "no trail this swing" --
-- an unregistered weapon id, a Tool that has not replicated yet, or a character with neither.
-- Which R6 limb a bare-hands swing strikes with: the Basic string alternates left hand, right hand, left
-- foot (AttackConstants.Presentation.SwingTrail.FistLimbByStage); everything else uses the default limb.
-- Pure, so Tests/FX/SwingTrail.spec.lua can pin the order without a rig.
function AttackTrail.FistLimbFor(kind: string, stageIndex: number): string
	if kind == "Basic" then
		local limb = TUNING.FistLimbByStage[stageIndex]
		if limb then
			return limb
		end
	end
	return TUNING.FistDefaultLimb
end

local function resolveAnchor(payload: AttackStartedPayload, currentCharacter: Model): (BasePart?, CFrame, CFrame)
	if payload.WeaponId == WeaponRoster.FISTS_ID then
		local limb = currentCharacter:FindFirstChild(AttackTrail.FistLimbFor(payload.Kind, payload.StageIndex))
		if limb and limb:IsA("BasePart") then
			return limb, CFrame.new(0, TUNING.FistOffsetStuds.Near, 0), CFrame.new(0, TUNING.FistOffsetStuds.Far, 0)
		end
		return nil, CFrame.identity, CFrame.identity
	end

	local tool = currentCharacter:FindFirstChild(WeaponConstants.Visual.ToolName)
	local handle = tool and (tool :: Instance):FindFirstChild("Handle")
	if handle and handle:IsA("BasePart") then
		return handle, CFrame.new(0, 0, TUNING.WeaponOffsetStuds.Near), CFrame.new(0, 0, TUNING.WeaponOffsetStuds.Far)
	end
	return nil, CFrame.identity, CFrame.identity
end

local function onAttackStarted(payload: AttackStartedPayload): ()
	if not TUNING.Enabled then
		return
	end
	-- A new swing always retires whatever the previous one left running -- a fast combo string must
	-- never show two overlapping trails, and one still fading out from a cancelled swing must not
	-- outlive the throw that replaced it.
	releaseTrail()

	local currentCharacter = character
	if not currentCharacter then
		return
	end

	local part, offsetNear, offsetFar = resolveAnchor(payload, currentCharacter)
	if not part then
		-- Not an error -- see this file's header on the Tool-replication race. Silent: a swing missing
		-- its trail once in a great while is not worth a log line on a hot path.
		return
	end

	-- Off until the windup ends -- see this file's header. Moved onto the anchor now (not at the enable
	-- moment) so the pair has settled by the time it draws; Roblox trails an Attachment from wherever it
	-- first renders, so moving it on the enable frame would draw a spurious segment from the old spot.
	acquire(part, offsetNear, offsetFar)

	-- The hit window plus a lead into it and a tail after it (SwingTrail.LeadSeconds/TailSeconds) --
	-- the trail traces the swing, the hitbox stays exactly the window.
	window = {
		startsAt = os.clock() + SwingLunge.DelayFor(payload.WindupSeconds, -TUNING.LeadSeconds),
		durationSeconds = payload.ActiveSeconds + TUNING.LeadSeconds + TUNING.TailSeconds,
	}
end

-- A swing ended early. A feint flares the trail as the feint cue; anything else simply drops it.
local function onSwingCancelled(reason: AttackInputClient.SwingCancelReason): ()
	local currentTrail = trail
	if reason ~= "Feint" or not TUNING.Enabled or not currentTrail or not currentTrail.Parent then
		releaseTrail()
		return
	end
	currentTrail.Color = TUNING.FeintColor
	currentTrail.Enabled = true
	window = {
		startsAt = os.clock(),
		durationSeconds = TUNING.FeintPulseSeconds,
	}
end

local function onHeartbeat(): ()
	local live = window
	if not live then
		return
	end

	local currentTrail = trail
	if not currentTrail or not currentTrail.Parent then
		-- The part it was parented to (a Tool, most likely) is gone -- a sheathe or a swap mid-swing.
		-- The next acquire notices the destroyed set and builds a fresh one.
		window = nil
		return
	end

	local elapsed = os.clock() - live.startsAt
	if elapsed < 0 then
		return
	end
	if elapsed >= live.durationSeconds then
		-- Disabled, not released -- Trail.Lifetime still has to fade out whatever segment is already
		-- drawn, which Clear would cut off mid-fade. The next acquire (the next swing) or a character
		-- rebind is what moves it on.
		currentTrail.Enabled = false
		window = nil
		return
	end
	if not currentTrail.Enabled then
		currentTrail.Enabled = true
	end
end

-- Preload hook, matching every other FX module's own -- a Trail's Color/Transparency/WidthScale carry
-- no asset id, so there is nothing here for Client/Loading/AssetPreloader.lua to warm; kept for
-- interface symmetry only. (Present for callers that iterate every FX module's GetPreloadInstances
-- uniformly; returns nothing to preload today.)
function AttackTrail.GetPreloadInstances(): { Instance }
	return {}
end

function AttackTrail.BindCharacter(newCharacter: Model): ()
	releaseTrail()
	character = newCharacter
end

function AttackTrail.Start(): ()
	if started then
		return
	end
	started = true

	startedDisconnect = AttackInputClient.OnAttackStarted(onAttackStarted)
	cancelledDisconnect = AttackInputClient.OnSwingCancelled(onSwingCancelled)
	heartbeatConnection = RunService.Heartbeat:Connect(onHeartbeat)

	logger:debug("AttackTrail started", { enabled = TUNING.Enabled })
end

function AttackTrail.Stop(): ()
	if not started then
		return
	end
	started = false

	if startedDisconnect then
		startedDisconnect()
		startedDisconnect = nil
	end
	if cancelledDisconnect then
		cancelledDisconnect()
		cancelledDisconnect = nil
	end
	if heartbeatConnection then
		heartbeatConnection:Disconnect()
		heartbeatConnection = nil
	end
	destroyTrail()
	character = nil
end

return AttackTrail
