--!strict
--[[
	MovementGuard.lua

	Owns: the server's speed and teleport check on ENGAGED players (the InCombat tag) -- whether a body moved the way
	a body obeying this game's movement could have. MovementGuardConstants has the numbers and the reason it exists
	now: lag-compensated hits test swings against positions the server recorded, so a client writing its own
	position would otherwise bend hit registration as well as movement.

	WHAT IT CAN AND CANNOT DO, said plainly (ParkourValidation's header makes the same point): a client owns its
	character's physics, so nothing server-side PREVENTS it moving itself. This WATCHES, and answers in the two ways
	that cost an honest player nothing:
	  * a strike suspends the lag-compensation benefit of that player's own swings for a few seconds
	    (HitboxEngine.SuspendCompensation) -- a body whose recent positions cannot be trusted is not handed the
	    advantage of rewinding its victims;
	  * a pattern of strikes flags the player ONCE per session for a human to review, through the shared
	    SuspicionLedger. Nothing is kicked, rubber-banded or punished automatically.

	ONLY WHILE ENGAGED, by design. Out of a fight there are no hits to bend, and the world's own movement (a mount, a
	cart, an admin teleport between zones) is not this module's business.

	EXCUSED, NOT JUDGED -- the track is reset and the next window starts fresh -- whenever the server itself is moving
	the body or has handed it a legitimate reason to move unusually:
	  * the server holds it (RootControlLocked: a swing lock, a stagger, a grab, an air combo, a mount) or it is
	    PlatformStanding, Grabbed, Mounted, Flying (admin), anchored, or dead;
	  * a launch or a server correction is in progress (KnockbackUntil -- DamageSystem's launches, a realm's pull and
	    containment, an admin teleport all stamp it);
	  * an air combo holds or carries it (AirHeldUntil / AirComboAttackerUntil present).
	A parkour action that owns the body's velocity (ParkourVelocityOwned, which the server itself grants for a
	validated report) is not excused but judged against ParkourValidation's own travel ceiling instead of
	WalkSpeed, and its climbs (a mantle, a ledge climb, a wall run) are not judged for rise.

	THE JUDGEMENT IS PURE AND LIVES APART (Shared/Combat/MovementJudge.lua): a track, a position, a time and the
	allowed speed in; a verdict out. Every Instance read is in sample() here, so the arithmetic is specced headless
	without the engine this module also requires.

	Does not own: the body (the client), WalkSpeed (RunSystem), the flag store (ModerationSystem), or what lag
	compensation does (HitboxEngine).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local AttributeConstants = require(ReplicatedStorage.Shared.AttributeConstants)
local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local Logger = require(ReplicatedStorage.Shared.Logger)
local MovementGuardConstants = require(ReplicatedStorage.Shared.Combat.MovementGuardConstants)
local MovementJudge = require(ReplicatedStorage.Shared.Combat.MovementJudge)
local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)
local Trove = require(ReplicatedStorage.Shared.Trove)
local Types = require(ReplicatedStorage.Shared.Types)

local GameplayEvents = require(ServerScriptService.Server.Events.GameplayEvents)
local SuspicionLedger = require(ServerScriptService.Server.Systems.Support.SuspicionLedger)
local HitboxEngine = require(script.Parent.HitboxEngine.HitboxEngine)

local logger = Logger.scope("MovementGuard")

local MovementGuard = {}

local CONFIG = MovementGuardConstants
local ATTRIBUTES = AttributeConstants

-- Runtime -----------------------------------------------------------------------------------------------------

local tracks: { [Player]: MovementJudge.Track } = {}
-- The highest speed each player was allowed recently, and when. Allowed speed can DROP faster than a body
-- sheds momentum: RunSystem ramps WalkSpeed toward zero while a parkour action owns the body, so the instant a
-- dash or slide hands control back, WalkSpeed is near zero and the body is still gliding at dash speed. Judging
-- that glide against the dropped number is a false positive on every honest dash. A window is therefore judged
-- against the best allowance it overlapped (CONFIG.Speed.CarrySeconds), never one sampled mid-ramp.
local recentAllowance: { [Player]: { Speed: number, At: number } } = {}
local ledger = SuspicionLedger.New({
	Name = "Movement",
	ReasonCode = "MovementImplausible",
	Summary = "implausible movement samples while in combat",
	Strikes = CONFIG.Flag.Strikes,
	WindowSeconds = CONFIG.Flag.WindowSeconds,
})
local tickDisconnect: (() -> ())? = nil
local lifecycle = Trove.New()
local sinceSample = 0
local started = false

-- Why `humanoid` is excused this sample, or nil when it is judged (see this file's header).
local function excuseOf(humanoid: Humanoid, root: BasePart, now: number): string?
	if humanoid.Health <= 0 then
		return "Dead"
	end
	if root.Anchored or humanoid.PlatformStand then
		return "Held"
	end
	if
		humanoid:GetAttribute(ATTRIBUTES.RootControlLocked) == true
		or humanoid:GetAttribute(ATTRIBUTES.Grabbed) == true
		or humanoid:GetAttribute(ATTRIBUTES.Mounted) == true
		or humanoid:GetAttribute(ATTRIBUTES.Flying) == true
	then
		return "ServerHeld"
	end
	local allowance = humanoid:GetAttribute(ATTRIBUTES.KnockbackUntil)
	if typeof(allowance) == "number" and now <= allowance then
		return "Launched"
	end
	if
		humanoid:GetAttribute(ATTRIBUTES.AirHeldUntil) ~= nil
		or humanoid:GetAttribute(ATTRIBUTES.AirComboAttackerUntil) ~= nil
	then
		return "AirCombo"
	end
	return nil
end

-- Whether a validated parkour action owns `humanoid`'s velocity -- server-set (ParkourSystem grants it for an
-- accepted report), unlike the client-only ParkourActionOwned, which never reaches the server.
local function parkourOwns(humanoid: Humanoid): boolean
	return humanoid:GetAttribute(ATTRIBUTES.ParkourVelocityOwned) == true
end

-- The horizontal speed `humanoid` may cover right now.
local function allowedSpeedOf(humanoid: Humanoid): number
	if parkourOwns(humanoid) then
		return ParkourConstants.Validation.MaxTravelSpeed
	end
	return math.max(humanoid.WalkSpeed, 1)
end

-- The allowed speed to judge this sample against: the current one, or a higher one granted within the carry.
local function allowanceFor(player: Player, current: number, now: number): number
	local recent = recentAllowance[player]
	if recent == nil or current >= recent.Speed or now - recent.At > CONFIG.Speed.CarrySeconds then
		recentAllowance[player] = { Speed = current, At = now }
		return current
	end
	return recent.Speed
end

local function sample(player: Player, now: number): ()
	local character, humanoid, root = CharacterUtil.LiveRig(player)
	local track = tracks[player]
	if character == nil or humanoid == nil or root == nil then
		if track then
			MovementJudge.ResetTrack(track)
		end
		return
	end
	if humanoid:GetAttribute(ATTRIBUTES.InCombat) ~= true then
		tracks[player] = nil
		recentAllowance[player] = nil
		return
	end
	if track == nil then
		track = MovementJudge.NewTrack()
		tracks[player] = track
	end
	local live = track :: MovementJudge.Track
	local allowed = allowanceFor(player, allowedSpeedOf(humanoid), now)
	if excuseOf(humanoid, root, now) ~= nil then
		MovementJudge.ResetTrack(live)
		return
	end

	local verdict, detail = MovementJudge.Judge(live, root.Position, now, allowed, not parkourOwns(humanoid))
	if verdict == "Ok" then
		return
	end
	logger:debug("Implausible movement while engaged", { player = player.Name, verdict = verdict, detail = detail })
	HitboxEngine.SuspendCompensation(character, now + CONFIG.SuspendCompensationSeconds)
	ledger:Strike(
		player,
		now,
		`{verdict}: {detail or ""}`,
		if verdict == "Teleport" then CONFIG.Teleport.StrikeWeight else 1
	)
end

local function step(deltaTime: number): ()
	sinceSample += deltaTime
	if sinceSample < CONFIG.SampleSeconds then
		return
	end
	sinceSample = 0
	local now = os.clock()
	for _, player in Players:GetPlayers() do
		sample(player, now)
	end
end

function MovementGuard.Init(): ()
	if started or not CONFIG.Enabled then
		return
	end
	started = true
	tickDisconnect = GameplayEvents.OnHeartbeatTick(step)
	lifecycle:Add(PlayerLifecycle.BindAllPlayers({
		Scope = "MovementGuard",
		-- A new body starts a new track: the respawn point is not a teleport.
		OnCharacter = function(player: Player, _character: Model, _humanoid: Humanoid)
			tracks[player] = nil
		end,
		OnPlayerRemoving = function(player: Player)
			tracks[player] = nil
			recentAllowance[player] = nil
			ledger:Release(player)
		end,
	}))
	logger:info("MovementGuard.Init() complete")
end

function MovementGuard.Shutdown(): ()
	if tickDisconnect then
		tickDisconnect()
		tickDisconnect = nil
	end
	lifecycle:Clean()
	started = false
end

-- Spec-only.
function MovementGuard.Reset(): ()
	MovementGuard.Shutdown()
	table.clear(tracks)
	table.clear(recentAllowance)
	ledger:Reset()
	sinceSample = 0
end

return MovementGuard :: Types.SystemModule & typeof(MovementGuard)
