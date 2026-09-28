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
	polled window is cleared by just dropping the reference. Enabled turns on when the windup ends
	(the arm is now actually moving through the strike) and off when ActiveSeconds does (the hitbox
	just closed) -- not tied to the animation's own total length, which includes recovery the trail has
	no reason to still be drawing through.

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

	TWO ATTACHMENTS BUILT FRESH PER SWING, not pooled per weapon. A swing is bounded by this game's own
	combat cadence (SwapCooldownSeconds, per-move Cooldown) to at most a few a second, nowhere near the
	frequency CLAUDE.md's performance guidance reserves pooling for, and a fresh Trail is what makes a
	weapon swap or a respawn mid-swing incapable of leaving a trail parented to a part that no longer
	exists.

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
local heartbeatConnection: RBXScriptConnection? = nil

-- Destroys whatever this module built for the swing in progress, if any. Safe to call with nothing
-- live -- every field is nil-checked, and Destroy on an already-destroyed Instance is a no-op in
-- Luau. Called both mid-swing (the swing's own ActiveSeconds elapsed) and out from under a swing that
-- never got the chance to finish (BindCharacter, Stop).
local function clearTrail(): ()
	if trail then
		trail:Destroy()
		trail = nil
	end
	if attachment0 then
		attachment0:Destroy()
		attachment0 = nil
	end
	if attachment1 then
		attachment1:Destroy()
		attachment1 = nil
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
	clearTrail()
	window = nil

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

	local a0 = Instance.new("Attachment")
	a0.Name = "AttackTrailNear"
	a0.CFrame = offsetNear
	a0.Parent = part

	local a1 = Instance.new("Attachment")
	a1.Name = "AttackTrailFar"
	a1.CFrame = offsetFar
	a1.Parent = part

	local newTrail = Instance.new("Trail")
	newTrail.Attachment0 = a0
	newTrail.Attachment1 = a1
	newTrail.Color = TUNING.Color
	newTrail.Transparency = TUNING.Transparency
	-- No Width: a Trail has none. Its thickness is the Attachment pair's separation -- see
	-- AttackConstants.Presentation.SwingTrail.
	newTrail.WidthScale = TUNING.WidthScale
	newTrail.Lifetime = TUNING.LifetimeSeconds
	-- Off until the windup ends -- see this file's header. Built now (not deferred to the enable
	-- moment) so Attachment0/Attachment1 are already parented and settled the instant it turns on;
	-- Roblox trails a brand-new Attachment pair from wherever they first render, so building them a
	-- beat early would otherwise draw a short, spurious segment from the part's origin.
	newTrail.Enabled = false
	newTrail.Parent = part

	attachment0 = a0
	attachment1 = a1
	trail = newTrail

	window = {
		startsAt = os.clock() + SwingLunge.DelayFor(payload.WindupSeconds, 0),
		durationSeconds = payload.ActiveSeconds,
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
		-- Destroying WOULD be redundant (Roblox already collected it with its parent) but the two
		-- Attachments are separate Instances that may or may not have gone with it depending on which
		-- one they were parented to; clearTrail's own nil-checks make this safe either way.
		clearTrail()
		window = nil
		return
	end

	local elapsed = os.clock() - live.startsAt
	if elapsed < 0 then
		return
	end
	if elapsed >= live.durationSeconds then
		-- Disabled, not destroyed -- Trail.Lifetime still has to fade out whatever segment is already
		-- drawn, which Destroy would cut off mid-fade. clearTrail's next call (the next swing, or a
		-- character rebind) is what actually reclaims the Instances.
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
	clearTrail()
	window = nil
	character = newCharacter
end

function AttackTrail.Start(): ()
	if started then
		return
	end
	started = true

	startedDisconnect = AttackInputClient.OnAttackStarted(onAttackStarted)
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
	if heartbeatConnection then
		heartbeatConnection:Disconnect()
		heartbeatConnection = nil
	end
	clearTrail()
	window = nil
	character = nil
end

return AttackTrail
