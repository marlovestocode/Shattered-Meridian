--!strict
--[[
	SwingLunge.lua

	Owns: the short forward step the LOCAL player's own body takes when a swing is confirmed --
	AttackConstants.Presentation.SwingLunge's distance/duration pair, turned into a decaying velocity
	held for the length of the window. The felt weight of a punch, on the one machine that can
	actually produce it.

	WHY THIS IS ON THE CLIENT AT ALL, when Server/Combat/Damage/DamageSystem.lua already has an
	attacker lunge. A player's character is network-owned by that player's client: the client
	simulates it and replicates the result, and the server's own copy is a follower. So a server-side
	Humanoid:Move() aimed at a PLAYER is overwritten by the owner's very next replicated frame and
	never reaches the simulation drawing that player -- it moves nobody, silently, with no error
	anywhere. DamageConstants.AttackerLunge is not wrong; it is simply only reachable for the bodies
	the SERVER owns, which is bots and training dummies, and it stays for exactly them. Movement a
	player is supposed to SEE has to be written where their character is simulated, which is here.

	DRIVEN BY Attack_Started, NOT BY A LANDED HIT, and the two are meaningfully different moments.
	The server-side lunge fires on a resolved contact, so it can only ever reward a swing that already
	connected. This fires on the throw -- the step is part of the swing, so a whiff carries exactly as
	far as a hit and the player learns one motion instead of two. It is also the confirmation rather
	than the press (see AttackInputClient's header on the no-prediction stance): the server has
	already accepted this swing by the time this runs, so nothing here can move a body for an attack
	that was refused.

	SCHEDULED AGAINST THAT SWING'S OWN WINDUP rather than starting on arrival. Attack_Started carries
	the WindupSeconds the server actually scheduled for this specific swing, and the step waits it out
	(plus the per-kind DelaySeconds offset) before the first velocity write. Windup is by definition
	the interval where the arm is cocking and nothing has happened yet, so its end is the moment the
	weight should go forward -- a body that lurches on the frame the button went down is moving before
	the arm is, which reads as being shoved rather than as throwing a punch.

	The number comes off the payload rather than out of this module because that is the value the
	server really used, which since AttackConstants.Windows may have been read from the clip's own
	AttackM<stage> marker instead of any hand-typed constant. A re-authored animation therefore moves
	the step with it. See Shared/Attack/AttackWindows.lua for the extraction, and note the failure mode
	it implies: a clip whose marker is wrong now desynchronises the STEP as well as the hitbox, so
	"the lunge fires at the wrong moment" is a reason to suspect the marker before suspecting this.

	NOTHING CANCELS A SCHEDULED STEP TODAY, and the delay is what makes that worth stating. A swing
	interrupted during its windup -- the attacker taken into hitstun, DamageSystem calling
	cancelSwingOf -- still steps when its timer comes up, because the attack layer publishes no
	cancellation to the owning client at all (there is no Attack_Cancelled remote, and no hitstun
	Attribute on Constants.Attributes for one to be read from). The visible cost is bounded: an
	interrupted attacker slides their authored distance once, and the per-frame guards below still stop
	it dead if they are killed or leave the ground. Closing it properly means the attack layer growing
	an "this swing is over" signal, which is that layer's call and not something to fake from here.

	NOT PREDICTION, and the distinction is the same one AttackInputClient draws for its FOV punch.
	This claims no hit, moves no hitbox and reverses nothing. It walks the character a couple of studs
	forward -- which is the one thing the client already has unconditional authority over, because
	that is what WASD is. The server re-derives every geometric fact from the character's real
	replicated rig on its own clock (HitboxEngine's "the pose is never baked" rule), so a body that
	stepped forward is simply a body that is where it is.

	WRITES VELOCITY THROUGH ParkourMotor.ApplyImpulse RATHER THAN TOUCHING THE ROOT DIRECTLY. That
	function is the existing single seam for "something outside the state machine needs this body to
	move now", and going through it buys the two refusals this module would otherwise have to
	re-implement and keep in sync: a kinematic traversal (a vault, a mantle) owns the body outright,
	and the server can hold root control (Constants.Attributes.RootControlLocked, admin flight/freeze).
	Both correctly mean "not now" for a swing step too, and both already return false there.

	NEVER WRITES WalkSpeed. Server/Systems/RunSystem.lua is the sole writer of that property and a
	second one is the exact bug its header exists to prevent -- a lunge expressed as a speed override
	would fight the run ladder for every frame it lasted. Velocity is a different property with a
	different owner, and this only holds it for the window.

	Y IS PRESERVED, NEVER ASSIGNED. The impulse is a full velocity vector, so writing a flat forward
	push into it would zero the character's vertical velocity every frame -- deleting a jump's rise
	and a fall's speed for anyone who swings mid-air. The horizontal axes are replaced and the
	vertical one is carried through untouched, the same decomposition Shared/Parkour/ParkourMath's
	solved arcs learned to make.

	Does not own: whether the swing happens (Server/Combat/Attack/AttackRequestSystem.lua), the swing
	animation or the FOV punch (Client/Combat/AttackInputClient.lua), what a landed hit costs
	(DamageSystem), or any movement outside this window (the parkour framework, RunController).
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AttackConstants = require(ReplicatedStorage.Shared.Attack.AttackConstants)
local AttackTypes = require(ReplicatedStorage.Shared.Attack.AttackTypes)
local Logger = require(ReplicatedStorage.Shared.Logger)
local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local ParkourMath = require(ReplicatedStorage.Shared.Parkour.ParkourMath)

local AttackInputClient = require(script.Parent.AttackInputClient)
local ParkourMotor = require(script.Parent.Parent.Parkour.ParkourMotor)

type AttackStartedPayload = AttackTypes.AttackStartedPayload

local logger = Logger.scope("SwingLunge")

local SwingLunge = {}

local humanoid: Humanoid? = nil
local rootPart: BasePart? = nil

-- The live window, or nil between swings -- covering BOTH the scheduled wait and the step itself, as
-- one record with one clock. Re-derived every frame from `startsAt` rather than scheduled with a
-- task.delay, the same single-heartbeat shape RunController's own header documents, and the delay is
-- what makes that shape earn its keep rather than just match a convention: a second swing landing
-- inside the first one's wait replaces this table and the first step is gone, where a task.delay
-- would need cancelling and would otherwise fire into a swing that no longer exists.
type Window = {
	-- When the STEP begins, not when the swing was thrown: os.clock() at arrival plus the scheduled
	-- delay. Everything below measures from here, so the speed curve never has to know a delay exists.
	startsAt: number,
	durationSeconds: number,
	-- Peak speed, in studs/second, at the instant the window opens. Precomputed once per swing
	-- because it is a pure function of the authored pair and nothing about it changes mid-window.
	peakSpeed: number,
}

local window: Window? = nil

local started = false
local heartbeatConnection: RBXScriptConnection? = nil
local startedDisconnect: (() -> ())? = nil

-- Speed at `elapsed` seconds into a step that covers `distanceStuds` in `durationSeconds`.
--
-- Linear decay from a peak to a standstill, chosen over a flat speed because a flat one ends with an
-- instantaneous stop -- the character snaps from full lunge speed to walking on a single frame, which
-- reads as a hitch rather than as a step. Decaying to exactly zero at the end of the window means the
-- last frame this module writes is already the speed the character is about to be left at, so there
-- is no discontinuity to see when it stops writing.
--
-- The peak is 2 * distance / duration rather than distance / duration: the area under a line falling
-- to zero is half a rectangle, so a step that must still COVER the authored distance has to start at
-- twice the average. Getting this wrong is silent -- it just travels half as far as the number says.
--
-- Pure, and separated from the frame loop for that reason: this is the whole behavior worth asserting
-- on, and a spec can check it without a rig, a Humanoid or a physics step.
function SwingLunge.SpeedAt(distanceStuds: number, durationSeconds: number, elapsed: number): number
	if durationSeconds <= 0 or distanceStuds <= 0 or elapsed < 0 or elapsed >= durationSeconds then
		return 0
	end
	local peak = 2 * distanceStuds / durationSeconds
	return peak * (1 - elapsed / durationSeconds)
end

-- How long after Attack_Started the step should begin: the swing's own windup plus the authored
-- offset, floored at zero.
--
-- The floor is the whole reason this is a function rather than an addition at the call site. A
-- negative DelaySeconds is the useful direction (it starts the lean slightly inside the windup), but
-- a stage whose windup is shorter than that offset would otherwise schedule a step in the past --
-- which, measured against os.clock(), is a step that fires instantly AND has already burned part of
-- its own duration, so it travels less than its authored distance for reasons nothing would explain.
-- Degrading to "immediately, at full distance" is the answer that stays legible.
function SwingLunge.DelayFor(windupSeconds: number, delaySeconds: number): number
	return math.max(0, windupSeconds + delaySeconds)
end

-- Whether the body is in a state where a forward step is meaningful. ParkourMotor.ApplyImpulse makes
-- the ownership refusals (see this file's header); this makes the two this module owns.
local function bodyAcceptsStep(currentHumanoid: Humanoid, currentRoot: BasePart): boolean
	if currentHumanoid.Health <= 0 or currentRoot.Parent == nil then
		return false
	end
	if AttackConstants.Presentation.SwingLunge.GroundedOnly and currentHumanoid.FloorMaterial == Enum.Material.Air then
		return false
	end
	return true
end

local function onAttackStarted(payload: AttackStartedPayload): ()
	local tuning = AttackConstants.Presentation.SwingLunge
	if not tuning.Enabled then
		return
	end

	local perKind = tuning.ByKind[payload.Kind]
	if not perKind then
		-- Hotbar, or a kind added to AttackTypes.AttackKind without a step authored for it. Silent by
		-- design: "this move does not step" is an ordinary authoring answer, not a fault.
		return
	end

	if not humanoid or not rootPart then
		return
	end

	-- Deliberately NOT gated on bodyAcceptsStep here, only when the step actually starts. Between this
	-- frame and then sits the whole windup, which is long enough for the answer to change: a swing
	-- thrown a moment before landing from a jump is grounded by the time its step is due, and refusing
	-- it now would drop a step that was going to be perfectly legal.
	--
	-- The server sends WindupSeconds on every payload; typechecked rather than trusted because this is
	-- remote data and the type annotation is a compile-time claim about it, not a runtime guarantee. A
	-- non-number reaching the arithmetic below would throw, and AttackInputClient dispatches its
	-- OnAttackStarted listeners in a bare loop rather than through a pcall -- so the error would unwind
	-- out of the remote handler and take every listener registered after this one down with it.
	local windupSeconds = if typeof(payload.WindupSeconds) == "number" then payload.WindupSeconds else 0

	-- Replaces any window still pending or running rather than stacking with it. A swing landing inside
	-- the previous swing's step is a faster string, not a double-speed character -- and one landing
	-- inside the previous swing's WAIT correctly cancels that wait, because the swing it was scheduled
	-- for has been superseded.
	window = {
		startsAt = os.clock() + SwingLunge.DelayFor(windupSeconds, perKind.DelaySeconds),
		durationSeconds = perKind.DurationSeconds,
		peakSpeed = SwingLunge.SpeedAt(perKind.DistanceStuds, perKind.DurationSeconds, 0),
	}
end

local function onHeartbeat(): ()
	local live = window
	if not live then
		return
	end

	local currentHumanoid, currentRoot = humanoid, rootPart
	if not currentHumanoid or not currentRoot then
		window = nil
		return
	end

	local elapsed = os.clock() - live.startsAt
	if elapsed < 0 then
		-- Still waiting out the windup. Nothing is checked and nothing is written -- the body is doing
		-- whatever the player is asking it to, which during a windup is correct.
		return
	end
	if elapsed >= live.durationSeconds then
		window = nil
		return
	end

	-- Checked on the step's own first frame rather than at the throw (see onAttackStarted), and on
	-- every frame after: a swing thrown on the last frame before walking off a ledge must stop pushing
	-- the moment the ground goes, or the step becomes a jump.
	if not bodyAcceptsStep(currentHumanoid, currentRoot) then
		window = nil
		return
	end

	local speed = live.peakSpeed * (1 - elapsed / live.durationSeconds)

	-- Read live rather than captured at the swing's start, so a player turning through the step
	-- carries the step with them instead of sliding sideways out of their own facing. LookVector is
	-- the body's facing, not the camera's -- the swing's own direction, which is what the server
	-- resolves the hitbox from too.
	local forward = ParkourMath.SafeUnit(ParkourMath.Flatten(currentRoot.CFrame.LookVector), Vector3.zero)
	if forward == Vector3.zero then
		return
	end

	-- Horizontal replaced, vertical carried -- see this file's header on why Y is never assigned.
	local existing = currentRoot.AssemblyLinearVelocity
	ParkourMotor.ApplyImpulse(Vector3.new(forward.X * speed, existing.Y, forward.Z * speed))
end

-- Every new life. Follows Main.client.lua's bindCharacterPresentation convention (CombatAnimator,
-- MovementVFX, RunController) rather than opening this module's own CharacterAdded connection, so
-- there is one place that decides what a new character is announced to.
function SwingLunge.BindCharacter(character: Model): ()
	-- Dropped before the lookups: a window belonging to the PREVIOUS body must never be carried into
	-- this one, and a failed lookup below has to leave this module inert rather than half-bound.
	window = nil
	humanoid = nil
	rootPart = nil

	local humanoidInstance = CharacterUtil.HumanoidOf(character)
	local rootInstance = CharacterUtil.RootOf(character)
	if not humanoidInstance or not rootInstance then
		logger:warn("BindCharacter: character has no Humanoid/HumanoidRootPart")
		return
	end

	humanoid = humanoidInstance
	rootPart = rootInstance
end

function SwingLunge.Start(): ()
	if started then
		return
	end
	started = true

	startedDisconnect = AttackInputClient.OnAttackStarted(onAttackStarted)
	-- One persistent connection, gated on `window` rather than connected per swing: a per-swing
	-- connection is one respawn away from being leaked, and the idle cost of this one is a nil check.
	heartbeatConnection = RunService.Heartbeat:Connect(onHeartbeat)

	logger:debug("SwingLunge started", { enabled = AttackConstants.Presentation.SwingLunge.Enabled })
end

function SwingLunge.Stop(): ()
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
	window = nil
end

-- Whether velocity is being written right now. False during a scheduled swing's windup wait, which is
-- the distinction IsPending below exists to cover -- a caller asking "is a step happening" and a
-- caller asking "is one coming" want different answers, and collapsing them into one would make a
-- waiting swing indistinguishable from no swing at all.
--
-- Read-only, for the debug overlay and for a spec that wants to assert on the scheduling decision
-- without inspecting a real body's physics response.
function SwingLunge.IsStepping(): boolean
	local live = window
	if not live then
		return false
	end
	local elapsed = os.clock() - live.startsAt
	return elapsed >= 0 and elapsed < live.durationSeconds
end

-- Whether a step is scheduled but has not begun -- the windup wait. Distinct from IsStepping above.
function SwingLunge.IsPending(): boolean
	local live = window
	return live ~= nil and os.clock() < live.startsAt
end

return SwingLunge
