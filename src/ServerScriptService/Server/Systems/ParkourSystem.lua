--!strict
--[[
	ParkourSystem.lua

	Owns: the server half of the Parkour System -- the two Parkour_* remotes, the plausibility gate
	every client action report passes through, the Humanoid Attributes that let the combat layer's
	WalkSpeed resolver cooperate with client-driven movement, and the expiry timer that guarantees a
	granted velocity-ownership window always closes.

	THE TRUST MODEL, stated honestly up front. Roblox gives a client network ownership of its own
	character's unanchored parts; a cheating client can move that character however it likes with or
	without this system. So this module does NOT claim to prevent movement exploits, and
	Shared/Parkour/ParkourValidation.lua's own header says the same at more length. What it actually
	buys, all three of which are real:
	  1. AGREEMENT. Server/Systems/RunSystem.lua's WalkSpeed resolver runs every server Heartbeat and
	     would fight a client-driven slide for the same body. The ParkourVelocityOwned Attribute is how
	     the server stands that resolver down for exactly as long as an accepted action lasts -- and
	     the expiry below is how it stands back up even if the client never says the action ended.
	  2. BOUNDED INFLUENCE. Exactly one client-supplied number reaches gameplay: the exit speed that
	     becomes the ParkourSpeedFloor momentum carry. It is validated here, capped again independently
	     in RunSystem's own parkourSpeedFloor, decays to nothing within a second, and is applied only to
	     the ladder's answer -- never to the zeroing tiers, so it can never peek through a freeze, a
	     flight, an emote lock or a parkour claim.
	  3. VISIBILITY. A client producing a sustained stream of impossible claims trips the existing
	     suspected-cheater path (ModerationSystem's "System"-sourced flag, which Types.SuspicionSource
	     already reserves for exactly this kind of automated detection) rather than being silently
	     tolerated.

	Never touches another System's private state. Every piece of cross-system signalling goes through
	Humanoid Attributes, the same shape AdminActionSystem's Flying/Frozen and EmoteSystem's
	EmoteMovementLocked already use to influence that same resolver -- which is why this System needed
	no change anywhere else beyond one call site, and why it can be removed again without unpicking
	anything.

	Does not own: any movement behavior or decision (Client/Parkour/* owns all of it), the WalkSpeed
	resolver itself (Server/Systems/RunSystem.lua), or the tunables (Shared/Parkour/ParkourConstants.lua).
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local Constants = require(ReplicatedStorage.Shared.Constants)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local ParkourTypes = require(ReplicatedStorage.Shared.Parkour.ParkourTypes)
local ParkourValidation = require(ReplicatedStorage.Shared.Parkour.ParkourValidation)
local RateLimiter = require(ReplicatedStorage.Shared.RateLimiter)
local Types = require(ReplicatedStorage.Shared.Types)
local Logger = require(ReplicatedStorage.Shared.Logger)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)

local ModerationSystem = require(script.Parent.ModerationSystem)

type ActionKind = ParkourTypes.ActionKind
type ActionReport = ParkourTypes.ActionReport
type RejectionReason = ParkourTypes.RejectionReason

local logger = Logger.scope("ParkourSystem")

local ParkourSystem = {}

local RemoteNames = ParkourConstants.Network.RemoteNames
local VALIDATION = ParkourConstants.Validation

-- The subset of ParkourConstants.Validation that Shared/Parkour/ParkourValidation.lua reads, built
-- ONCE at module load and shared by both call sites (Validate and ResolveMomentumCarry). Both run on
-- every accepted report, so rebuilding this table per report -- as the Validate call site used to --
-- was pure allocation on a per-action path, and having two copies invited them to drift.
local VALIDATION_CONFIG: ParkourValidation.ValidationConfig = {
	MaxReportedSpeed = VALIDATION.MaxReportedSpeed,
	MaxTravelSpeed = VALIDATION.MaxTravelSpeed,
	MaxActionSeconds = VALIDATION.MaxActionSeconds,
	MomentumCarryObservedTolerance = VALIDATION.MomentumCarryObservedTolerance,
	MomentumCarryObservedSlackStuds = VALIDATION.MomentumCarryObservedSlackStuds,
}

-- Per-player server-side view of what that client claims to be doing. Deliberately minimal: this is
-- bookkeeping for the ownership window and the validator, NOT a mirror of the client's state machine.
-- The server has no opinion about whether a player is wall-running versus sliding -- only about
-- whether someone currently owns their velocity, since that is the only thing that changes what the
-- server itself does.
type PlayerParkourState = {
	OpenKind: ActionKind?,
	OpenStartedAt: number?,
	OpenStartPosition: Vector3?,
	-- Wall-clock deadline after which the ownership window is force-closed regardless of the client.
	OpenExpiresAt: number,
	LastPerKind: { [string]: number },
	-- Timestamps of recent rejections, pruned to VALIDATION.RejectionWindowSeconds.
	Rejections: { number },
	-- True once this player has been flagged this session, so a sustained stream of bad reports
	-- produces one flag rather than one per report past the threshold.
	Flagged: boolean,
}

local playerStates: { [Player]: PlayerParkourState } = {}

-- Subscribers to OnActionStarted. See that function's own header.
local actionStartedCallbacks: { (player: Player, kind: ActionKind, now: number) -> () } = {}

-- Only the rejection remote is held: this System FIRES that one (notifyRejected), where the report
-- remote is purely subscribed to in Init and never referenced again, so keeping a local for it would
-- be a variable that exists only for symmetry.
local rejectedRemote: RemoteEvent? = nil

-- One shared budget across the single remote this System owns. Sized from
-- ParkourConstants.Network.MaxReportsPerSecondPerPlayer rather than Constants.NetworkBudget's default
-- 4/s -- see that constant's own header for why a legitimate fast chain genuinely needs more, and why
-- throttling one would desync the server's view of who owns velocity.
local rateLimiter = RateLimiter.New(ParkourConstants.Network.MaxReportsPerSecondPerPlayer)

local function getState(player: Player): PlayerParkourState
	local existing = playerStates[player]
	if existing then
		return existing
	end
	local created: PlayerParkourState = {
		OpenKind = nil,
		OpenStartedAt = nil,
		OpenStartPosition = nil,
		OpenExpiresAt = 0,
		LastPerKind = {},
		Rejections = {},
		Flagged = false,
	}
	playerStates[player] = created
	return created
end

-- Clears every Attribute this System sets. Called when an action ends, when its window expires, on
-- respawn and on leave -- every path out of ownership, without exception, because an unreleased
-- ParkourVelocityOwned pins that player's WalkSpeed at zero for the rest of their life.
local function releaseOwnership(player: Player): ()
	local _, humanoid = CharacterUtil.LiveRig(player)
	if not humanoid then
		return
	end
	humanoid:SetAttribute(Constants.Attributes.ParkourVelocityOwned, false)
	humanoid:SetAttribute(Constants.Attributes.ParkourState, "")
end

local function notifyRejected(
	player: Player,
	kind: ActionKind,
	phase: ParkourTypes.ActionPhase,
	reason: RejectionReason
): ()
	local remote = rejectedRemote
	if not remote then
		return
	end
	remote:FireClient(player, { Kind = kind, Phase = phase, Reason = reason } :: ParkourTypes.ActionRejectedPayload)
end

-- Records a rejection and flags the player if they have produced enough of them inside the window.
-- Flagging is deliberately one-way per session (state.Flagged) -- a player who trips the threshold
-- once has already generated the record a human moderator needs, and re-flagging every subsequent
-- report would spam the suspicion DataStore for no additional information.
-- The two rejections an honest knockback launch can cause: the body moved faster, or further, than a
-- parkour action alone could have carried it. Every other reason is about the report itself.
local KNOCKBACK_DISTORTABLE: { [RejectionReason]: boolean } = {
	ImplausibleSpeed = true,
	ImplausibleTravel = true,
}

local function noteRejection(player: Player, state: PlayerParkourState, reason: RejectionReason, now: number): ()
	-- Inside a knockback allowance (Attributes.KnockbackUntil, stamped by DamageSystem on every launch it
	-- hands this player), a speed/travel rejection is still a rejection -- nothing is granted -- but it
	-- is not EVIDENCE: the combat layer moved this body, not the client. Counting it would flag the
	-- players who get hit hardest. Knockback compliance has its own detector (KnockbackAudit).
	if KNOCKBACK_DISTORTABLE[reason] then
		local _, humanoid = CharacterUtil.LiveRig(player)
		local allowance = if humanoid then humanoid:GetAttribute(Constants.Attributes.KnockbackUntil) else nil
		if typeof(allowance) == "number" and now <= allowance then
			return
		end
	end
	table.insert(state.Rejections, now)
	local count = ParkourValidation.PruneRejections(state.Rejections, now, VALIDATION.RejectionWindowSeconds)
	if state.Flagged or not ParkourValidation.ShouldFlag(count, VALIDATION.RejectionsBeforeFlag) then
		return
	end
	state.Flagged = true
	logger:warn("Flagging player for sustained implausible parkour reports", {
		player = player.Name,
		userId = player.UserId,
		rejectionsInWindow = count,
		lastReason = reason,
	})
	-- "System", not "Manual" -- Types.SuspicionSource reserves that member for exactly this: an
	-- automated detector with no individual admin behind it, hence the nil flaggedByUserId.
	ModerationSystem.FlagSuspectedCheater(
		player.UserId,
		nil,
		`Parkour: {count} implausible movement reports within {VALIDATION.RejectionWindowSeconds}s (last: {reason})`,
		"System" :: Types.SuspicionSource
	)
end

-- Grants velocity ownership for an accepted Start report.
local function beginAction(player: Player, state: PlayerParkourState, report: ActionReport, now: number): ()
	local _, humanoid = CharacterUtil.LiveRig(player)
	if not humanoid then
		return
	end

	state.OpenKind = report.Kind
	state.OpenStartedAt = now
	state.OpenStartPosition = report.Position
	-- The client's own claimed duration, clamped -- ParkourValidation has already refused a duration
	-- outside the legal range, so this is the belt-and-braces clamp for the nil case (a client that
	-- sent no duration at all, which is structurally valid).
	local duration = math.clamp(report.DurationSeconds or VALIDATION.MaxActionSeconds, 0, VALIDATION.MaxActionSeconds)
	state.OpenExpiresAt = now + duration

	humanoid:SetAttribute(Constants.Attributes.ParkourVelocityOwned, true)
	humanoid:SetAttribute(Constants.Attributes.ParkourState, report.Kind)
	-- Any momentum carry from a PREVIOUS action ends the moment a new one begins: the new action is
	-- now driving velocity directly, and a stale floor would apply the instant it ended, on top of
	-- whatever the new action's own exit grants.
	humanoid:SetAttribute(Constants.Attributes.ParkourSpeedFloor, 0)
	humanoid:SetAttribute(Constants.Attributes.ParkourSpeedFloorExpiry, 0)

	-- Announced last, once every Attribute above is already written, so a subscriber reading them sees
	-- the action it is being told about rather than the one before it.
	for _, callback in actionStartedCallbacks do
		-- pcall'd for the reason DefenseSystem's own emit gives: one subscriber erroring must not abort
		-- the rest, and above all must not unwind out of the remote handler with the window half-opened.
		local ok, err = pcall(callback, player, report.Kind, now)
		if not ok then
			logger:error("A ParkourSystem.OnActionStarted consumer errored", { errorMessage = tostring(err) })
		end
	end
end

-- Closes an ownership window and stamps the momentum carry the action ended with. `reportedSpeed` is
-- the single client-supplied number that reaches gameplay in this whole feature -- already validated
-- against VALIDATION.MaxReportedSpeed by the time it arrives here, and capped a second time,
-- independently, inside Server/Systems/RunSystem.lua's own parkourSpeedFloor.
-- CLOSING A WINDOW AND GRANTING A REWARD ARE TWO DIFFERENT JOBS, and conflating them was a real
-- exploit. `hadOpenWindow` is what separates them.
--
-- ParkourValidation deliberately ACCEPTS an End that matches no open window -- correctly, because the
-- server expires windows on its own and a slightly-late End is the ordinary, benign case, while
-- refusing one can only ever strand an honest player's movement. But "this report is not worth
-- rejecting" was being read as "this report earned a momentum carry," so an End needed no Start at
-- all to stamp the speed floor. See ParkourConstants.Validation.MomentumCarryObservedTolerance for
-- the exploit that followed from it.
--
-- So: the release half below is unconditional (it must be -- that is the whole reason an unmatched
-- End is honored), and only the carry half is gated on there having actually been an action.
local function endAction(
	player: Player,
	state: PlayerParkourState,
	reportedSpeed: number,
	now: number,
	hadOpenWindow: boolean
): ()
	state.OpenKind = nil
	state.OpenStartedAt = nil
	state.OpenStartPosition = nil
	state.OpenExpiresAt = 0

	local _, humanoid = CharacterUtil.LiveRig(player)
	if not humanoid then
		return
	end
	humanoid:SetAttribute(Constants.Attributes.ParkourVelocityOwned, false)
	humanoid:SetAttribute(Constants.Attributes.ParkourState, "")

	-- What the server can SEE the body doing, planar only -- the carry governs WalkSpeed, so a fall's
	-- vertical component must not inflate it. nil when the root can't be read at all, which
	-- ResolveMomentumCarry treats as "no observed ceiling available."
	local observedPlanar: number? = nil
	local _, _, rootPart = CharacterUtil.LiveRig(player)
	if rootPart then
		local velocity = rootPart.AssemblyLinearVelocity
		observedPlanar = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
	end

	local carry =
		ParkourValidation.ResolveMomentumCarry(reportedSpeed, observedPlanar, hadOpenWindow, VALIDATION_CONFIG)
	if carry == nil then
		-- No action was open, so there is no momentum to carry out of one. Deliberately does NOT zero
		-- an existing floor: a carry stamped by a genuine action that ended moments ago is still
		-- legitimately running out its MomentumCarrySeconds, and a stray End must not be able to
		-- cancel it any more than it can grant one.
		return
	end

	humanoid:SetAttribute(Constants.Attributes.ParkourSpeedFloor, carry)
	humanoid:SetAttribute(
		Constants.Attributes.ParkourSpeedFloorExpiry,
		now + ParkourConstants.Locomotion.MomentumCarrySeconds
	)
end

local function handleReport(player: Player, rawPayload: unknown): ()
	if not ParkourConstants.Enabled then
		return
	end
	local now = os.clock()
	local state = getState(player)

	if rateLimiter:IsLimited(player) then
		-- Deliberately NOT counted as a rejection toward the cheater flag: hitting a rate limit is
		-- something a laggy or momentarily-thrashing honest client does, and conflating "too many
		-- reports" with "physically impossible reports" would flag exactly the players least able to
		-- do anything about it.
		logger:debug("Parkour report rate limited", { player = player.Name })
		return
	end

	local report, parseError = ParkourValidation.Parse(rawPayload)
	if not report then
		local reason = parseError or "MalformedPayload"
		logger:debug("Parkour report malformed", { player = player.Name, reason = reason })
		noteRejection(player, state, reason, now)
		return
	end

	-- ONE LiveRig for both the root and the Humanoid. This function used to call it twice, eleven
	-- lines apart, each time discarding two of the three values -- and each call re-walks the
	-- character's children twice (FindFirstChildOfClass for the Humanoid, FindFirstChild for the
	-- root). Same answers, half the scans, and no window in which the two calls could disagree about
	-- which character they were looking at.
	local _, humanoid, rootPart = CharacterUtil.LiveRig(player)
	if not rootPart then
		notifyRejected(player, report.Kind, report.Phase, "NoCharacter")
		return
	end

	-- The combat layer's own hold on the body outranks any movement claim. A client reporting a
	-- wall-run while the server has it ragdolled or air-combo-held is either desynced or lying; either
	-- way granting velocity ownership would put the parkour framework and RagdollController's
	-- AlignPosition pin on the same body at once. The client's own controller independently parks in
	-- its AerialCombat state for the same signal, so an honest client never reaches this branch.
	if humanoid and humanoid:GetAttribute(Constants.Attributes.RootControlLocked) == true then
		notifyRejected(player, report.Kind, report.Phase, "CombatRestricted")
		return
	end

	local accepted, rejectionReason = ParkourValidation.Validate(report, {
		Position = rootPart.Position,
		Now = now,
		OpenKind = state.OpenKind,
		OpenStartedAt = state.OpenStartedAt,
		OpenStartPosition = state.OpenStartPosition,
		LastSameKindAt = state.LastPerKind[report.Kind] or 0,
		MinSameKindIntervalSeconds = ParkourConstants.Network.MinSameActionIntervalSeconds,
	}, VALIDATION_CONFIG)

	if not accepted then
		local reason = rejectionReason or "MalformedPayload"
		logger:debug("Parkour report rejected", {
			player = player.Name,
			kind = report.Kind,
			phase = report.Phase,
			reason = reason,
		})
		noteRejection(player, state, reason, now)
		notifyRejected(player, report.Kind, report.Phase, reason)
		-- A rejected report leaves any open window alone rather than force-closing it: the rejection is
		-- about THIS claim, and tearing down a window the player is legitimately inside would strand
		-- their movement mid-action for a claim that may simply have arrived out of order.
		return
	end

	state.LastPerKind[report.Kind] = now
	if report.Phase == "Start" then
		beginAction(player, state, report, now)
	else
		-- Read BEFORE endAction clears it. An End earns its momentum carry only if it is closing a
		-- window this same kind actually opened -- see endAction's own header.
		local hadOpenWindow = state.OpenKind == report.Kind and state.OpenStartedAt ~= nil
		endAction(player, state, report.Speed, now, hadOpenWindow)
	end
end

-- Force-closes any ownership window whose deadline has passed. THE reason this System has a Heartbeat
-- at all, and non-negotiable: without it, a client that disconnects, crashes, or simply drops its End
-- report mid-slide leaves ParkourVelocityOwned true forever, and Server/Systems/RunSystem.lua's
-- resolver pins that character's WalkSpeed at zero for the rest of their life with no error anywhere
-- to explain it.
-- The client's own reported duration (already clamped) is what sets each deadline, so the window is
-- never shorter than the action legitimately needs.
local function onHeartbeat(): ()
	local now = os.clock()
	for player, state in pairs(playerStates) do
		if state.OpenKind ~= nil and now >= state.OpenExpiresAt then
			logger:debug("Parkour ownership window expired without an End report", {
				player = player.Name,
				kind = state.OpenKind,
			})
			-- Expired rather than ended: no momentum carry is granted, because the client never told us
			-- what speed it finished with and inventing one would be handing out free speed for a
			-- dropped packet. Passed as hadOpenWindow = false for exactly that reason -- there WAS an
			-- open window (that is why we are here), but it is being torn down rather than completed,
			-- and only a completed action earns a carry. beginAction already zeroed the floor when this
			-- window opened, so skipping the stamp leaves it at zero either way.
			endAction(player, state, 0, now, false)
		end
	end
end

local function onCharacterAdded(player: Player): ()
	-- A fresh character's Humanoid never carries the previous one's Attributes, but the per-player
	-- window bookkeeping lives here and does survive a respawn -- so it is cleared explicitly. Without
	-- this, dying mid-slide would leave an open window pointing at a character that no longer exists,
	-- and the expiry above would then "end" an action on the new one.
	local state = getState(player)
	state.OpenKind = nil
	state.OpenStartedAt = nil
	state.OpenStartPosition = nil
	state.OpenExpiresAt = 0
	releaseOwnership(player)
end

-- Fires once per ACCEPTED Start report, with the player, the action kind and the server time it was
-- accepted -- after validation, after the ownership window opened. Rejected reports never fire it.
-- Returns a disconnect function, matching DefenseSystem.OnResolved's own contract.
--
-- THIS SYSTEM'S FIRST PUBLIC SURFACE, and it is a signal rather than a query on purpose. Its one
-- subscriber today is the composition root, which turns an accepted Roll into
-- DefenseSystem.BeginEvade -- the roll's evade frames. The subscription lives in Main.server.lua and not
-- in either System, so this module never learns combat exists and DefenseSystem never learns parkour
-- does: the same "the boot script knows both, each layer knows one" shape SetParryAnimation is wired
-- through.
--
-- Accepted, not claimed, is the whole value: the evade is keyed off the SAME plausibility gate that
-- decides whether the roll's velocity ownership is granted, so a report the server refused as
-- implausible can never open a window.
function ParkourSystem.OnActionStarted(callback: (player: Player, kind: ActionKind, now: number) -> ()): () -> ()
	table.insert(actionStartedCallbacks, callback)
	return function()
		local index = table.find(actionStartedCallbacks, callback)
		if index then
			table.remove(actionStartedCallbacks, index)
		end
	end
end

function ParkourSystem.Init(): ()
	local report = NetworkBridge.CreateRemoteEvent(RemoteNames.ReportAction)
	report.OnServerEvent:Connect(handleReport)

	rejectedRemote = NetworkBridge.CreateRemoteEvent(RemoteNames.ActionRejected)

	-- See Shared/PlayerLifecycle.lua -- the add/sweep/remove triple plus the per-player character
	-- hookup, in one call instead of four places that all had to agree.
	PlayerLifecycle.BindAllPlayers({
		Scope = "ParkourSystem",
		OnPlayer = function(player: Player)
			getState(player)
		end,
		OnPlayerRemoving = function(player: Player)
			playerStates[player] = nil
			rateLimiter:Clear(player)
		end,
		OnCharacter = function(player: Player)
			onCharacterAdded(player)
		end,
	})
	-- Players who joined before this System booted (a fast rejoin during server start) still need
	-- their per-player state and character hook -- the same Init()-time sweep every other
	-- PlayerAdded-driven System in this codebase uses as its backstop.
	RunService.Heartbeat:Connect(onHeartbeat)

	logger:info("ParkourSystem.Init() complete", { enabled = ParkourConstants.Enabled })
end

return ParkourSystem :: Types.SystemModule & typeof(ParkourSystem)
