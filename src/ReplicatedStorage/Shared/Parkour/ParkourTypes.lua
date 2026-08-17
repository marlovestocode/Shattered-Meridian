--!strict
--[[
	ParkourTypes.lua

	Owns: every type the parkour framework's own modules pass between each other -- the movement
	state union, the probe result shapes, the per-frame context, the state-module interface, and the
	client->server report payload. Types only; no runtime value, no state, no behavior.

	Scoped one level down from ReplicatedStorage/Shared/Types.lua for exactly the reason
	Server/Combat/CombatTypes.lua is scoped down from it: these shapes are internal to one feature's
	own module cluster, not a system boundary. The ONE type here that genuinely crosses a system
	boundary -- ActionReport, the client->server remote payload -- is re-exported by Types.lua as
	Types.ParkourActionReport so no System outside this feature ever has to require this file, the
	same discipline every other cross-boundary payload in this codebase follows.

	Does not own: the numbers those shapes are populated with (Shared/Parkour/ParkourConstants.lua),
	or any decision made from them.
]]

local ParkourTypes = {}

-- Every movement state the framework can be in. Adding a mechanic means adding a member here and a
-- module under Client/Parkour/States/ -- nothing else in the framework switches on this union
-- exhaustively (the state machine dispatches through the registry, and the animator/camera/debug
-- layers all key off it by lookup with a documented fallback), which is the concrete mechanism
-- behind the design's "modular so additional movement mechanics can be added later without
-- rewriting the entire movement system."
--
-- "AerialCombat" is the combat-owned carve-out: while a player is being juggled, is mid-air-combo
-- chase, or is ragdolled, the parkour system parks in this state and drives NOTHING -- see
-- States/AerialCombat.lua for why yielding entirely (rather than trying to force the character back
-- onto ground movement) is the only correct behavior when CombatSystem/RagdollController already
-- own the body.
export type MovementStateId =
	"Idle"
	| "Walking"
	| "Sprinting"
	| "Jumping"
	| "Falling"
	| "Landing"
	| "Sliding"
	| "Vaulting"
	| "Mantling"
	| "WallRunning"
	| "WallJumping"
	| "LedgeHanging"
	| "LedgeClimbing"
	| "Rolling"
	| "Leaping"
	| "LedgeLeaping"
	| "AerialCombat"

-- How the motor is driving the character this frame. Each state declares one; ParkourMotor.lua is
-- the only module that reads it, and the only module in the whole codebase that writes the
-- character's velocity/CFrame on behalf of parkour.
--   * "Humanoid"  -- Roblox's own character controller drives movement; the motor only supplies a
--                    momentum-derived speed the SERVER applies to WalkSpeed. Slopes, steps, stairs
--                    and jumping all keep working exactly as the engine intends.
--   * "Velocity"  -- a LinearVelocity constraint drives the assembly at a commanded world velocity,
--                    with gravity fully or partly cancelled. Real collision still applies.
--   * "Kinematic" -- a rigid (RigidityEnabled = true) AlignPosition drives the root to a commanded
--                    world position every physics step, exactly, along an authored path. The root
--                    stays unanchored throughout -- see Client/Parkour/ParkourMotor.lua's own header
--                    for why an anchored version of this used to exist and why it does not any more
--                    (an anchored part never replicates to other clients at all). Effectively
--                    uninterruptible-by-physics, for traversals that MUST land where they claim.
export type DriveMode = "Humanoid" | "Velocity" | "Kinematic"

-- Which discrete action a report refers to. A subset of MovementStateId: only the states that
-- actually take ownership of velocity (and therefore need the server to stand its own WalkSpeed
-- resolver down) are reportable -- Idle/Walking/Sprinting/Jumping/Falling are ordinary Humanoid
-- locomotion the server already governs and are deliberately NOT network events.
export type ActionKind = "Slide" | "Vault" | "Mantle" | "WallRun" | "WallJump" | "LedgeClimb" | "Roll" | "Leap"

-- What a report is saying about that action.
export type ActionPhase = "Start" | "End"

-- The client->server payload (Constants' Parkour_ReportAction remote). Every field is re-validated
-- server-side regardless of what the client sends -- see Shared/Parkour/ParkourValidation.lua.
-- Position/Speed are included NOT because the server trusts them (it reads the character's real
-- replicated position itself) but so the validator can compare the claim against reality and
-- reject a client whose story doesn't match its own body.
export type ActionReport = {
	Kind: ActionKind,
	Phase: ActionPhase,
	-- Planar speed the client believes it has at this moment.
	Speed: number,
	-- Client's own position at report time.
	Position: Vector3,
	-- How long this action is expected to last (Start reports only) -- lets the server expire an
	-- ownership window on its own if the End report never arrives, rather than trusting a client to
	-- always hand velocity back.
	DurationSeconds: number?,
}

-- Why a report was refused. Mirrors Types.ActionRejectedPayload's Reason field convention (a stable
-- machine-readable string, logged server-side and surfaced to the acting client so its own state
-- machine can roll back rather than desyncing).
export type RejectionReason =
	"Disabled"
	| "RateLimited"
	| "NoCharacter"
	| "MalformedPayload"
	| "ImplausibleSpeed"
	| "ImplausibleTravel"
	| "ImplausibleVerticalGain"
	| "ActionTooLong"
	| "DuplicateAction"
	| "CombatRestricted"

export type ActionRejectedPayload = {
	Kind: ActionKind,
	Phase: ActionPhase,
	Reason: RejectionReason,
}

-- One raycast/spatial-probe result, reused frame to frame rather than reallocated -- see
-- EnvironmentProbe.lua's own header for why every probe result in this framework is a persistent
-- mutable table and never a fresh allocation.
export type ProbeResult = {
	-- False when this probe found nothing; every other field is stale/meaningless when so.
	Hit: boolean,
	Position: Vector3,
	Normal: Vector3,
	Distance: number,
	Instance: BasePart?,
	Material: Enum.Material,
	-- os.clock() at which this result was produced -- the cache-staleness check.
	SampledAt: number,
}

-- Ground state beneath the character.
export type GroundProbe = {
	Grounded: boolean,
	-- True when a floor was found within the probe's full reach but further than the "grounded"
	-- threshold -- the "about to land" band the jump buffer and the animator both read.
	NearGround: boolean,
	Distance: number,
	Normal: Vector3,
	-- Surface angle from horizontal, in degrees.
	SlopeAngle: number,
	Standable: boolean,
	Material: Enum.Material,
	Instance: BasePart?,
	-- Slide friction multiplier authored on this surface (ParkourConstants.Tags.
	-- SurfaceFrictionAttribute), 1 when unset.
	FrictionScale: number,
	SampledAt: number,
}

-- What's directly in front of the character, measured well enough for ObstacleClassifier.lua to
-- decide what to do about it. Heights are relative to the character's FOOT plane.
export type ObstacleProbe = {
	Found: boolean,
	-- Horizontal distance from the character to the obstacle's near face.
	Distance: number,
	-- Height of the obstacle's top surface above the foot plane. Infinity when the probe never
	-- found a top (a wall taller than the sampled band).
	Height: number,
	-- Depth from near face to far edge along the travel direction. Infinity when no far edge was
	-- found within the sampled range.
	Depth: number,
	-- Outward normal of the near face.
	Normal: Vector3,
	-- World position of the top surface directly above the near face -- the anchor point every
	-- traversal path is built from.
	TopPosition: Vector3,
	-- The (flattened, unit) direction EnvironmentProbe.probeObstacle actually cast along to find this
	-- obstacle -- frozen at probe time, not re-derived. TopPosition, Depth and Normal above are all
	-- geometry measured along this exact vector, so a traversal state that built its path from a
	-- freshly-recomputed direction instead (StateSupport.TravelDirection, which can legitimately
	-- disagree by the time Enter runs -- a reversed key, MoveIntent leading MoveDirection right at the
	-- commit threshold) would be describing a curve toward geometry that was found somewhere else. See
	-- States/Mantling.lua and States/Vaulting.lua Enter for the consumer. Zero when Found is false.
	TravelDirection: Vector3,
	-- Whether there is somewhere to land on the far side (vault) and somewhere to stand on top
	-- (mantle). Both are probed, both are needed, and they are different questions.
	HasLandingSpace: boolean,
	HasStandingSpace: boolean,
	Instance: BasePart?,
	-- Resolved from ParkourTagging.lua -- a designer's explicit allow/deny for this surface.
	VaultAllowed: boolean,
	MantleAllowed: boolean,
	SampledAt: number,
}

-- A wall beside the character, on one side.
export type WallProbe = {
	Found: boolean,
	Distance: number,
	-- Where the side cast actually met the wall. Distance and Normal alone cannot reconstruct this --
	-- the cast runs along the character's own right vector, which is not the wall's normal for anything
	-- but a perfectly square approach -- and the assisted wall-jump needs the real contact point to
	-- refuse aiming back at the face it just left (ParkourConstants.WallJump.Assist.SameWallIgnoreRadius).
	-- Zero when Found is false.
	Position: Vector3,
	Normal: Vector3,
	-- The horizontal unit vector ALONG the wall, oriented to agree with the character's current
	-- travel direction -- what a wall-run actually moves along. Zero when Found is false.
	Tangent: Vector3,
	-- Degrees the surface tilts away from vertical. A wall-run requires this under
	-- ParkourConstants.WallRun.MaxSurfaceTiltDegrees.
	TiltAngle: number,
	Instance: BasePart?,
	WallRunAllowed: boolean,
	BounceScale: number,
	SampledAt: number,
}

-- A grabbable edge found while airborne.
export type LedgeProbe = {
	Found: boolean,
	-- World position of the edge itself (the lip the hands go on).
	EdgePosition: Vector3,
	-- Outward normal of the wall face BELOW the edge -- what the character hangs facing into.
	WallNormal: Vector3,
	HasStandingSpace: boolean,
	-- Whether there is room to actually HANG below this edge -- i.e. whether the pose the hang would
	-- put the character in has their feet in open air rather than jammed into the floor. The
	-- counterpart to HasStandingSpace on the other side of the edge, and needed for the same reason:
	-- an edge can be geometrically grabbable and still be too close to the ground for a hang to mean
	-- anything. See EnvironmentProbe.probeLedge for the measurement.
	HasHangSpace: boolean,
	Instance: BasePart?,
	Allowed: boolean,
	SampledAt: number,
}

-- The surface an assisted wall-jump has decided to aim at. Produced on demand by
-- EnvironmentProbe.FindWallJumpTarget at the instant of the jump -- not a per-frame probe result, which
-- is why it is not a field on ParkourContext: nothing between two wall-jumps has any use for it, and a
-- context field would be a stale answer sitting in scope for the whole life.
export type WallJumpTarget = {
	Found: boolean,
	-- Where the trajectory is actually aimed: out from the surface along its own normal, so the arrival
	-- is BESIDE the wall (where the wall probes can find it and a wall-run can attach) rather than inside
	-- it.
	AimPosition: Vector3,
	-- The surface hit itself, kept distinct from AimPosition because the two answer different questions:
	-- this one is what the debug overlay draws and what a same-wall comparison is made against.
	SurfacePosition: Vector3,
	Normal: Vector3,
	Instance: BasePart?,
	Distance: number,
	-- ParkourMath.WallJumpCandidateScore's verdict for the chosen candidate. Zero when Found is false,
	-- and zero for a corridor target, which is selected by geometry rather than by ranking.
	Score: number,
	-- True when this is the far wall of a CORRIDOR -- a surface facing back at the one being jumped from.
	-- The two cases produce completely different jumps (across versus up), so the distinction has to
	-- survive the trip back to States/WallJumping rather than being re-derived there from the normal.
	Corridor: boolean,
}

-- Where a leap has decided to land. Produced on demand by EnvironmentProbe.FindLeapTarget at the moment
-- of the double tap, for the same reason WallJumpTarget is: nothing between two leaps has any use for
-- it, and a context field would be a stale answer sitting in scope for the whole life.
export type LeapTarget = {
	Found: boolean,
	-- The point the arc is solved to land on -- already pulled in from the surface's near edge by
	-- ParkourConstants.Leap.LandingInsetStuds, so the character lands ON the ledge rather than at its
	-- lip with half of them over the drop.
	LandingPosition: Vector3,
	Normal: Vector3,
	Instance: BasePart?,
	-- Planar distance from the launch. The debug overlay's readout, and the honest measure of what the
	-- scan actually chose.
	Distance: number,
}

-- Where a LEDGE-TO-LEDGE leap has decided to land -- produced on demand by EnvironmentProbe.
-- FindLedgeLeapTarget, the moment States/LedgeHanging.lua's Update sees a directional jump press while
-- hanging. Sibling to LeapTarget above rather than a reuse of it: that one aims at any surface a
-- downward cast finds; this one aims specifically at a GRABBABLE EDGE (a wall face plus a lip within
-- the hang band), because arriving at an ordinary floor from a hang is not the move this searches for
-- -- the player let go and fell for that, they did not need to aim.
export type LedgeLeapTarget = {
	Found: boolean,
	-- Where the ARC is solved to land: the hang pose at the found edge (ParkourMath.HangPosition), not
	-- the edge itself -- solving to the lip would fly the character INTO the wall face on arrival
	-- rather than into the hang.
	LandingPosition: Vector3,
	EdgePosition: Vector3,
	WallNormal: Vector3,
	Instance: BasePart?,
	Distance: number,
}

-- Everything a state module is given each frame. One persistent table, mutated in place by the
-- controller and handed to whichever state is active -- never reallocated, and never retained by a
-- state past the call it was passed in (see StateMachine.lua's own contract).
export type ParkourContext = {
	Character: Model,
	Humanoid: Humanoid,
	RootPart: BasePart,

	DeltaTime: number,
	Now: number,

	-- Which state is running right now, and which one ran immediately before it. Set by
	-- StateMachine.lua before any state callback fires, so a CanEnter predicate can legally depend on
	-- where the character is coming from -- LedgeClimbing may only be entered from LedgeHanging,
	-- Rolling only from the states in ParkourConstants.Roll.AllowedFromStates, and both express that
	-- by reading CurrentStateId rather than by the machine hardcoding a transition table (which is
	-- what would make adding a state a multi-file edit again).
	CurrentStateId: MovementStateId,
	PreviousStateId: MovementStateId,
	-- Seconds the current state has been active. Maintained by the machine, so no state has to keep
	-- its own entry timestamp for the near-universal "has my window elapsed" check.
	StateElapsed: number,

	-- Camera-relative movement intent this frame, already flattened and normalized (magnitude 0 or
	-- 1). The single input every state reads -- no state polls UserInputService itself.
	MoveIntent: Vector3,
	-- Where the player is LOOKING: the camera's own unit look vector, pitch included. Distinct from both
	-- MoveIntent (where they are asking to go) and RootPart.CFrame.LookVector (where the body is turned,
	-- which is flat and, outside shift lock, lags the camera entirely).
	--
	-- Supplied by the controller rather than read by the state that wants it, because reaching for
	-- Workspace.CurrentCamera from inside a movement state would put a camera dependency in the one layer
	-- this framework keeps free of them. Only States/Leaping reads it so far -- the leap is aimed at what
	-- the player is looking at, including up at a higher ledge or down into a courtyard, which is the one
	-- question neither of the other two vectors can answer.
	AimDirection: Vector3,
	-- Whether sprint is currently engaged, by whichever route (held key, toggle, or Autorun) --
	-- pushed in from CombatClient.lua, which remains the owner of sprint. See ParkourController.
	-- SetSprinting.
	SprintHeld: boolean,
	-- Which run stage the SERVER currently has this character in: 0 = not sprinting, 1 = ordinary
	-- sprint, 2 = the sustained full-stride stage reached after Constants.Combat.
	-- SprintStage2ThresholdSeconds of unbroken running. Mirrored from Constants.Attributes.SprintStage
	-- by the controller each frame -- the client never resolves it, since the stage decides a WalkSpeed
	-- multiplier (see Server/Combat/Movement.UpdateSprintStage).
	--
	-- Distinct from SprintHeld above, which is the player's INTENT: a player can be holding sprint
	-- (SprintHeld true) at stage 1, at stage 2, or -- while blocking or mid-commitment -- at a stage
	-- the server is not currently granting the speed for at all. States that care about how fast the
	-- character is actually allowed to be must read this, not the intent.
	SprintStage: number,

	-- Live motion. Momentum is the framework's own authoritative planar speed (states read and
	-- write it; it is what survives a state transition); Velocity is the character's actual measured
	-- assembly velocity, which can disagree with Momentum during physics-driven states and is what
	-- the validator/animator read.
	Momentum: number,
	MoveDirection: Vector3,
	Velocity: Vector3,
	VerticalVelocity: number,
	PlanarSpeed: number,

	-- Probe results. Populated by EnvironmentProbe.Update before the active state's Update runs;
	-- which of them are FRESH this frame depends on what the current state requested (see
	-- StateDefinition.Probes below).
	Ground: GroundProbe,
	Obstacle: ObstacleProbe,
	WallLeft: WallProbe,
	WallRight: WallProbe,
	Ledge: LedgeProbe,
	CeilingClear: boolean,

	-- Fall bookkeeping, maintained by the controller across frames: the highest Y reached since
	-- leaving the ground, and the resulting fall height at the moment of contact.
	ApexHeight: number,
	FallHeight: number,
	-- os.clock() the character last left the ground -- the coyote-time reference.
	LeftGroundAt: number,
	-- os.clock() the character last touched the ground -- the wall-run/wall-jump chain reset
	-- reference.
	LastGroundedAt: number,

	-- How many wall-runs/wall-jumps have happened since the last ground contact -- the anti-infinite
	-- -climb counters. Reset by the controller on grounding, incremented by the states themselves.
	WallRunChain: number,
	WallJumpChain: number,
	-- The last wall part attached to, and when it was left -- the SameWallLockout reference.
	LastWallInstance: BasePart?,
	LastWallLeftAt: number,

	-- True while the combat layer has taken the body (ragdoll, air-combo hold/chase, an emote lock,
	-- flight, or an admin freeze) -- read from the Humanoid Attributes the server already publishes.
	-- The single gate that hands control back to combat, checked by the controller before any state
	-- runs.
	CombatOwned: boolean,

	-- Whether this player is currently IN COMBAT -- mirrored from the Constants.Attributes.InCombat
	-- Humanoid Attribute the server publishes, read every frame beside the four CombatOwned reads.
	--
	-- Distinct from CombatOwned above, and the distinction matters: CombatOwned means something else is
	-- DRIVING the body (a ragdoll, a hold, flight, an admin freeze) and parkour must get out of the way
	-- entirely. InCombat means the player is merely fighting -- they still own their own movement, they
	-- just are not allowed the full traversal set while doing it. See
	-- ParkourConstants.CombatGate.BlockedStates for which states that removes and why.
	InCombat: boolean,

	-- Player-configurable assist flags, resolved once per settings change rather than per frame.
	Assists: AssistSettings,

	-- What the motor should do this frame. States write here instead of touching the character --
	-- see MotorCommand below for why every velocity write in this framework funnels through one
	-- struct and one applier.
	Motor: MotorCommand,

	-- Presentation hints the active state publishes for the controller to act on, so the animator,
	-- camera and VFX layers never have to re-derive information the state already knew.
	--   * AnimationVariant distinguishes clips within one state (wall-run left vs. right, vault-over
	--     vs. hop) without inventing a MovementStateId per variant.
	--   * LandingSeverity is set by States/Falling.lua at the moment of contact and read by
	--     States/Landing.lua, the camera dip and the shake preset -- all three need the same answer
	--     and must not classify it independently.
	AnimationVariant: string?,
	LandingSeverity: ("Soft" | "Medium" | "Hard")?,

	-- The edge States/LedgeHanging.lua latched onto, published for States/LedgeClimbing.lua to build
	-- its climb path from. Handed over rather than re-probed because by the time the character is
	-- HANGING, the ledge probe can no longer see the edge it is holding -- the probe scans a band
	-- around head height, and a hanging character's head is below the lip by construction. Two flat
	-- fields rather than a nested table so the hand-off costs no allocation on a path that runs every
	-- time a player catches an edge.
	LedgeAnchorPosition: Vector3?,
	LedgeAnchorNormal: Vector3?,

	-- DEBUG-ONLY ANNOTATIONS. Nothing in this framework reads any of these three for a gameplay
	-- decision -- their one consumer is Client/Parkour/ParkourDebug.lua's "LIVE MECHANICS" section,
	-- which shows the shimmy, the ledge-to-ledge leap and the wall-run corner turn the same way the
	-- rest of the overlay shows every other refusal reason: verbatim, not inferred from watching the
	-- character move. All three are refreshed to a fresh value at the TOP of the writing state's own
	-- Update, every frame that state is active -- never left stale from a previous frame -- so the
	-- overlay's gate ("only show this row while CurrentStateId is the state that writes it") is always
	-- reading this frame's answer, not a stranded one from three seconds ago.
	--
	-- States/LedgeHanging.lua, every frame it runs:
	DebugShimmy: ("Idle" | "Straight" | "Corner" | "Refused")?,
	DebugLedgeLeap: ("Idle" | "NoIntent" | "NoTarget" | "Unreachable" | "Launched")?,
	-- States/WallRunning.lua, every frame it runs:
	DebugWallRunPivot: ("Straight" | "Pivoted")?,
}

-- The player's own movement preferences (Settings System). Mirrors the shape persisted on
-- Types.PlayerSettings.Parkour -- see that field's own header. Defaults come from
-- ParkourConstants.Assists / .Enabled, so an absent preference always means "whatever the game
-- currently ships as the default," never a hardcoded second opinion.
export type AssistSettings = {
	CoyoteTime: boolean,
	JumpBuffer: boolean,
	AutoVault: boolean,
	LedgeAssist: boolean,
	StepAssist: boolean,
}

-- What a state asks the environment probe to keep fresh while it's active. Anything not listed is
-- served from cache at its own ParkourConstants.Probe interval (or skipped entirely while the
-- character is slow enough to have nothing to detect) -- this is the whole mechanism by which the
-- framework's per-frame raycast cost scales with what's actually being done, rather than casting
-- every probe every frame forever.
export type ProbeRequest = {
	Ground: boolean?,
	Obstacle: boolean?,
	Walls: boolean?,
	Ledge: boolean?,
	Ceiling: boolean?,
}

-- What a state's Update returns: the id to transition into, or nil to stay. A state never applies
-- its own transition -- StateMachine.lua owns that, so every transition passes through one place
-- that can log it, feed the debug overlay, and enforce the CanEnter contract.
export type TransitionResult = MovementStateId?

-- One movement state module. Every file under Client/Parkour/States/ returns exactly this shape,
-- and the registry (States/init.lua) is the only thing that knows they exist -- adding a state is
-- one new file plus one line in that registry.
--
-- Contract notes that are load-bearing rather than stylistic:
--   * CanEnter is a PURE PREDICATE. It must not mutate context or the character -- the state
--     machine calls it speculatively on states the player may never actually enter, and the debug
--     overlay calls it on EVERY registered state every readout to display why each action is or is
--     not currently available (the design's "why a parkour action was or was not allowed").
--   * Enter/Exit are allowed to mutate; Update is allowed to mutate and must return a
--     TransitionResult.
--   * Priority orders speculative entry when several states would accept at once: highest wins.
--     Used for the genuinely-simultaneous cases (a vault and a mantle both viable on the same
--     obstacle; a ledge grab and a wall-run both viable on the same wall).
export type StateDefinition = {
	Id: MovementStateId,
	Priority: number,
	Drive: DriveMode,
	-- Probes this state needs kept fresh while active.
	Probes: ProbeRequest,
	-- Whether this state, while active, blocks speculative entry into other states -- a committed
	-- traversal (vault/mantle/climb) sets this so nothing can steal the character mid-animation.
	Committed: boolean?,
	-- The action this state reports to the server on entry/exit, if any.
	Reports: ActionKind?,
	CanEnter: (context: ParkourContext) -> (boolean, string?),
	Enter: ((context: ParkourContext, previous: MovementStateId) -> ())?,
	Update: (context: ParkourContext) -> TransitionResult,
	Exit: ((context: ParkourContext, nextState: MovementStateId) -> ())?,
}

-- What the motor is being asked to do this frame. States write into this (via the controller's own
-- accessors) rather than touching the character; ParkourMotor.Apply is what commits it. Keeping the
-- write in one place is what makes "two systems fighting over character velocity" -- the failure
-- mode the design explicitly calls out -- structurally impossible within this framework.
export type MotorCommand = {
	Mode: DriveMode,
	-- Velocity mode: the commanded world velocity.
	Velocity: Vector3,
	-- Whether gravity should be cancelled this frame (Velocity mode only).
	CancelGravity: boolean,
	-- INFORMATIONAL ONLY. The planar speed the active state believes it wants; read by the debug
	-- overlay and nothing else.
	--
	-- It is deliberately NOT a way to move the character, and it is worth being blunt about that
	-- because the shape invites the assumption: ordinary running speed belongs to
	-- Server/Combat/Movement.ComputeDesiredWalkSpeed, which runs on the server every Heartbeat and has
	-- no knowledge of slope. Writing a slope-adjusted number here does not make a character run faster
	-- downhill, and an earlier version of this comment claimed it was "published to the server as a
	-- momentum floor" -- it never was. The momentum floor is published only on a parkour ACTION's End
	-- report (Server/Systems/ParkourSystem.lua), never per frame.
	--
	-- Slope therefore expresses itself through the SLIDE, not through running: past
	-- Slope.ForcedSlideAngleDegrees the ground takes the character into States/Sliding.lua, which owns
	-- its own velocity and does model gravity properly. That is the parkour-correct answer as well as
	-- the cheap one -- a real steep descent should be a controlled slide, not a faster jog.
	DesiredSpeed: number,
	-- Kinematic mode: where the root should be this frame.
	TargetCFrame: CFrame?,
	-- Facing the character should be turned toward, or nil to leave facing alone.
	FaceDirection: Vector3?,
	-- Hip-height delta applied this frame (slide crouch), restored automatically when it returns to
	-- zero.
	HipHeightDelta: number,
}

return ParkourTypes
