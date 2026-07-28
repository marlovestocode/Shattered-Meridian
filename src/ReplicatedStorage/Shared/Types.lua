--!strict
--[[
	Types.lua

	Owns: every shared type definition used across server Systems, client modules, and the
	network boundary. Does not own runtime values -- see Constants.lua for tunables and
	NetworkBridge.lua for remote payload wiring built on top of these types.
]]

local Types = {}

export type Faction = "Celestial" | "Demonic" | "Unbound"

export type Region = "TheVoid" | "TheMedianParadise" | "TheDemonicDisastrousLandscape"

-- 1-9. Tier names/thresholds are a technical-design decision owned by TierSystem, not yet
-- finalized -- see progression-systems.md. Kept numeric until that design lands.
export type Tier = number

-- world-bible.md's four fixed races, named now that CharacterCreationSystem.lua (chargen) needs a
-- closed set to validate a client-submitted race choice against -- supersedes this field's former
-- "stays opaque, no named roster yet" comment. BloodlineId/ArtId stay opaque strings below: unlike
-- races, progression-systems.md's 13 bloodlines and ArtSystem's arts have no fixed, chargen-facing
-- roster yet for anything to validate against.
export type RaceId = "Human" | "Firmborn" | "Rivenkin" | "Hollowborn"
export type BloodlineId = string
export type ArtId = string

-- The six chargen attributes (Constants.CharacterCreation), a named record rather than a
-- `{ [string]: number }` dict -- every consumer (validation, the Attributes screen, Confirmation's
-- summary) works with exactly these six known fields, never an arbitrary/open set, so a typo'd key
-- is a compile-time error instead of a silently-missing stat. See Constants.CharacterCreation's own
-- header for what each attribute drives.
export type AttributeBlock = {
	Vitality: number,
	Fortitude: number,
	MeridianFlow: number,
	Might: number,
	Pressure: number,
	Fleetness: number,
}

export type PlayerProfile = {
	userId: number,
	faction: Faction?,
	raceId: RaceId?,
	-- In-game character name, chosen at chargen (CharacterCreationSystem.lua) -- distinct from the
	-- Roblox username (Player.Name/DisplayName), not globally unique, no reservation table. nil
	-- exactly when raceId is nil (a player who hasn't been through chargen yet) -- the two fields are
	-- written together in one Transform (CharacterCreationSystem.handleFinalize), never independently.
	displayName: string?,
	-- Chargen attribute allocation (CharacterCreationSystem.lua). nil exactly when raceId is nil, same
	-- "written together, one Transform" contract as displayName above. Additive by construction (a
	-- future Attunement/tier-up points-per-tier screen, explicitly out of scope for chargen itself,
	-- adds to these fields rather than replacing them) -- nothing here assumes attributes are only
	-- ever set once.
	attributes: AttributeBlock?,
	tier: Tier,
	bloodlineIds: { BloodlineId },
	artMastery: { [ArtId]: number },
	corruption: number,
	qiDeviationRisk: number,
	factionStanding: number,
	hasAscended: boolean,
}

-- Persisted wrapper around PlayerProfile (PlayerDataSystem.lua, software-architecture.md's
-- "Canonical player data read/write, DataStore integration" ownership row). SchemaVersion is a
-- DataStore-record concern only -- it lets PlayerDataSystem.MigrateRecord detect and upgrade an
-- older on-disk shape before ever handing a live PlayerProfile to another System -- and
-- deliberately does NOT appear on PlayerProfile itself, since every other System's public API
-- already types against the bare in-memory shape and has no reason to know or care what schema
-- version it was loaded from.
export type StoredPlayerProfile = {
	SchemaVersion: number,
	Profile: PlayerProfile,
}

-- Every server System/Manager conforms to this lifecycle so Main.server.lua can boot them
-- uniformly and so no module reaches into another's internals directly (software-architecture.md).
export type SystemModule = {
	Init: () -> (),
}

-- Combat (CombatSystem, software-architecture.md's ownership row; combat-philosophy.md for the
-- Lock-on/Block/Parry/Posture feel these shapes carry state for). Defined here, not locally in
-- CombatSystem.lua, because each of these genuinely crosses a boundary this file's header reserves
-- for shared types: CombatVitalsPayload/CombatFeedbackPayload cross the client/server network
-- boundary over NetworkBridge remotes; CombatSnapshot crosses the CombatSystem-to-future-System
-- module boundary via CombatSystem.GetCombatState. CombatSystem's own internal, mutable
-- per-player state is NOT here -- that never leaves CombatSystem.lua, per software-architecture.md's
-- "no system reaches into another system's internals directly."

export type CombatFeedbackKind =
	"Hit"
	| "Blocked"
	| "Parried"
	| "PostureBreak"
	| "Death"
	| "Disarmed"
	-- A successful air-tech escape (CombatSystem.lua's handleAirTechRequest) -- sent to both the
	-- escaping victim and the punished attacker, same "both sides get the same payload" shape as
	-- "Parried" above.
	| "AirTechEscaped"

export type CombatVitalsPayload = {
	Health: number,
	MaxHealth: number,
	Posture: number,
	MaxPosture: number,
}

export type CombatFeedbackPayload = {
	Kind: CombatFeedbackKind,
	AttackerUserId: number?,
	TargetUserId: number?,
	-- Authoritative world position of the target at the moment of resolution. Optional and
	-- additive -- existing player-vs-player feedback doesn't set it (CombatClient.lua already
	-- resolves position from TargetUserId for those). Populated for targets that have no
	-- TargetUserId to resolve from, e.g. a training dummy, which is not a Player.
	TargetPosition: Vector3?,
	DamageAmount: number?,
	PostureAmount: number?,
	IsHeavy: boolean?,
	-- The landing attack's DebugName (e.g. "Basic2"), set only for Kind == "Hit"/"Blocked" --
	-- lets the DEFENDER's own client pick a matching hit-reaction animation (CombatAnimator.
	-- PlayHitReaction reuses the same trailing-digit stage extraction PlaySwing already uses for
	-- the attacker's own swing animation). Not consumed for any gameplay/hit decision.
	AttackDebugName: string?,
}

-- Which weapon a player currently fights with (Constants.Combat.Weapons) -- CombatSystem.lua's
-- selectAttackDefinition reads a weapon's own Basic/Heavy/Finisher stage arrays instead of a
-- single flat table, and RequestSwapWeapon toggles a player's CombatState.equippedWeaponId between
-- these two. A closed union (matching FinisherVariant/DefenseKind's style) rather than an open
-- string since there are exactly two, both known here. Bots stay on Constants.Combat.Weapons.
-- Default permanently -- see BotState/handleSwapWeaponRequest's own comments for why bot
-- weapon-switching is out of scope.
export type WeaponId = "Primary" | "Secondary"

-- Sent to the attacking player only, the moment CombatSystem accepts their attack request (after
-- every validation and cooldown/commitment commit -- never optimistic). Carries just enough
-- timing/identity for the client-side animation/FX layer (Client/FX/CombatAnimator.lua) to sync a
-- swing's telegraph and active window to what the server actually scheduled -- not damage-relevant,
-- and CombatClient.lua does not use it for any hit/damage decision. WeaponId is additive (which
-- weapon's stage threw this swing), also not consumed for any gameplay decision. FinisherVariant is
-- non-nil only when this throw is the M1 combo's 4th hit -- already decided server-side at throw
-- time (HitResolution.SelectFinisherVariant), included here purely so CombatAnimator can pick the
-- Uppercut animation over a routine swing; it is NOT how the server decides the finisher's actual
-- knockback (that's threaded through the hit-resolution pipeline separately, this is a read-only
-- echo of the same already-server-authoritative decision).
export type AttackStartedPayload = {
	IsHeavy: boolean,
	DebugName: string,
	WindupSeconds: number,
	ActiveSeconds: number,
	RecoverySeconds: number,
	-- The thrown stage's own Cooldown (Constants' per-stage value, echoed so PredictionMirror can
	-- mirror basicAttackReadyAt/heavyAttackReadyAt without a client-side reverse lookup of
	-- WeaponId+DebugName back into the Constants stage tables). Additive and read-only like the rest
	-- of this payload -- the server's own cooldown commit in commitAndThrowAttack is the authority.
	CooldownSeconds: number?,
	WeaponId: WeaponId?,
	FinisherVariant: FinisherVariant?,
}

-- Sent to the acting player only, the moment CombatSystem accepts a Dash (after every validation
-- and the commitment/cooldown commit -- never optimistic). The movement counterpart of
-- AttackStartedPayload: carries just enough for the animation/FX layer (Client/FX/
-- CombatAnimator.lua) to time a dash-step to the server-scheduled window. Not damage-relevant and
-- not consumed for any gameplay decision. DurationSeconds is the committed action window (the
-- attackEndsAt lock this action set) -- Sprint is deliberately absent from this payload entirely --
-- it's a sustained WalkSpeed state reflected by Roblox's default run cycle, not a one-shot action
-- needing a synced animation cue.
export type MovementPerformedPayload = {
	DurationSeconds: number,
	-- The Dash cooldown Movement.ApplyDash actually just committed (Constants.Combat.
	-- DashCooldownSeconds normally, DashBackCooldownSeconds for a backward dash) -- echoed so
	-- PredictionMirror.OnMovementPerformed can mirror the REAL cooldown rather than always assuming
	-- the plain constant regardless of direction. Additive and read-only like AttackStartedPayload's
	-- own CooldownSeconds field, same reasoning. Optional so a nil falls back to the old plain-
	-- constant behavior (defensive, should always be sent by the current server).
	CooldownSeconds: number?,
}

-- Sent to the acting player only, the moment CombatSystem accepts a Slide (after every validation,
-- including the Slide-specific sprinting/moving preconditions -- see CombatSystem.lua's
-- handleSlideRequest). Kept as its OWN payload/remote rather than reusing MovementPerformedPayload:
-- that one is already disambiguated between plain-Dash and DashPunch by comparing its
-- DurationSeconds against a known constant (PredictionMirror.OnMovementPerformed) -- stacking a
-- third meaning onto the same numeric-comparison trick would only compound an already-fragile
-- pattern, and Slide has its own real precondition (state.sprinting) Dash doesn't, which is cleaner
-- to confirm through a dedicated echo.
export type SlidePerformedPayload = {
	DurationSeconds: number,
}

-- Sent to the acting player only, the moment CombatSystem accepts a BlockStart request -- the
-- block counterpart of AttackStartedPayload/MovementPerformedPayload. ParryWindowOpened reflects
-- whether this particular press was off the parry cooldown (Constants.Combat.ParryCooldownSeconds)
-- and therefore actually armed a timed parry window, vs. a plain block while still on cooldown --
-- state the client has no other way to know, since parryAvailable is computed server-side only
-- (CombatSystem.lua's handleBlockStart). Lets CombatAnimator play a parry-flash synced to the
-- server's real parryWindowExpiry instead of guessing from raw input. Not consumed for any
-- gameplay/hit decision.
export type BlockStartedPayload = {
	ParryWindowOpened: boolean,
	ParryWindowSeconds: number,
}

-- Which client-predictable request a Combat_ActionRejected event refers to -- exactly the six
-- actions CombatClient plays optimistic local feedback for at press time (Basic/Heavy share one
-- prediction slot, "Swing" -- see Constants.Combat.Prediction). Matches the prediction/feedback the
-- client recorded at press time so it knows what to roll back. Sprint's entry is the visual-only
-- kind: CombatSystem.lua's handleSprintStart plays no PredictionMirror slot (WalkSpeed's own
-- server-authoritative gate is what actually decides whether sprinting takes effect), but the
-- client still optimistically plays a running animation/VFX/FOV zoom on keydown, so a genuine
-- reject (e.g. Ragdolled) still needs a rollback signal the same as every other predicted action --
-- see CombatClient's Combat_ActionRejected handler.
export type RejectedActionKind = "Basic" | "Heavy" | "Dash" | "BlockStart" | "Slide" | "Sprint"

-- Sent to the acting player only, when a Basic/Heavy/Dash/BlockStart/Slide/Sprint request is
-- genuinely rejected -- the rollback counterpart of the AttackStartedPayload/
-- MovementPerformedPayload/BlockStartedPayload/SlidePerformedPayload confirm echoes (Sprint has no
-- confirm echo of its own -- see RemoteNames.MovementPerformed's header -- so its rollback is the
-- ONLY server->client signal tied to a SprintStart request at all). NEVER fired for the
-- too-early-but-buffered attack pseudo-reject (the buffered press still produces its confirm echo
-- when it flushes) and never for Stop actions (always honored). Reason is the same reject-reason
-- string logRejected records server-side ("Stunned", "DashCooldownActive", ...) -- diagnostic only:
-- the client's rollback needs only Action and logs Reason for debugging. PredictionMirror does NOT
-- parse it -- it self-corrects from the feedback stream plus the OnPredictionPending horizon (see
-- CombatClient's Combat_ActionRejected handler).
export type ActionRejectedPayload = {
	Action: RejectedActionKind,
	Reason: string,
}

-- Sent to the acting player only, the moment CombatSystem accepts a Feint (RequestFeint,
-- CombatSystem.lua's handleFeintRequest) -- cancels the player's own Basic/Heavy/Finisher/AirSlam
-- swing while it's still telegraphing, before the hitbox can ever go active. Unlike Basic/Heavy/
-- Dash/BlockStart/Slide, Feint has no predict-then-rollback pair (no ActionRejectedPayload case):
-- the client's own local cancel of its currently-playing swing animation
-- (CombatAnimator.CancelActiveSwing) is fired unconditionally at press time and is always safe
-- regardless of whether the server ultimately accepts it (see CombatClient.lua's Feint input
-- branch), so a rejection needs no rollback -- there is nothing wrong to undo. RecoverySeconds is
-- the new (shorter) attackEndsAt commitment the feint replaced the swing's own remaining windup+
-- active+recovery with -- PredictionMirror.OnFeintPerformed assigns it the same way
-- OnMovementPerformed/OnSlidePerformed assign their own commitment durations, so a follow-up press
-- shortly after a feint still gets accurate prediction instead of staying conservatively locked out
-- for the ORIGINAL (longer) swing's commitment.
export type FeintPerformedPayload = {
	RecoverySeconds: number,
}

-- The knockback variant a clean (non-blocked, non-parried) hit applies, via
-- HitResolution.ApplyFinisherPhysics/Server/Combat/RagdollController.lua. Two distinct sources
-- produce these today:
--   * The M1 combo finisher (Constants.Combat.BasicComboLength, always grounded -- see
--     HitResolution.SelectFinisherVariant's own header) chooses Uppercut when the attacker is
--     holding jump (launch the target up + ragdoll), Normal otherwise (a grounded heavier final
--     hit, no launch).
--   * The standalone AirSlam attack (Constants.Combat.AirSlam, jump + M1 at any time -- see
--     CombatSystem.lua's throwAirSlam) always throws with Downslam (slam the target to the
--     ground) -- the M1 finisher itself can no longer produce Downslam, since an airborne
--     Basic-attack press is intercepted into AirSlam before the finisher logic ever runs.
-- Not a network payload on its own -- it's threaded through the server-side hit pipeline
-- (startAttackSwing/throwAirSlam -> onSwingHitCandidate -> resolveHit*), the same way isHeavy is.
export type FinisherVariant = "Uppercut" | "Downslam" | "Normal"

-- Sent to the owning player only, when the M1 combo's finisher becomes ready or unready (i.e. when 3
-- basic hits have landed in a row, or the combo resets/lapses). The client uses FinisherReady to
-- suppress its own jump on the 4th hit so pressing Space fires the Uppercut instead of jumping -- see
-- CombatSystem.lua's syncFinisherReady and CombatClient.lua. Not damage-relevant and never trusted
-- back: it's a one-way server->client reflection of server-authoritative combo state.
export type ComboStatePayload = {
	FinisherReady: boolean,
}

-- Server -> owning client, fired only on a true/false transition of CombatState.inCombatUntil (see
-- that field's own header) -- the same "fire on transition" shape as ComboStatePayload above, for
-- the HUD's combat-state badge (Components/CombatStateBadge.lua).
export type InCombatPayload = {
	InCombat: boolean,
}

-- Read-only projection of a player's combat state for future systems (RewardSystem,
-- RivalrySystem, BountySystem, etc.) via CombatSystem.GetCombatState -- never the live mutable
-- state table itself.
export type CombatSnapshot = {
	Alive: boolean,
	Health: number,
	MaxHealth: number,
	Posture: number,
	MaxPosture: number,
	Blocking: boolean,
	Stunned: boolean,
	PostureBroken: boolean,
	-- True while CombatState.disarmedUntil/BotState.disarmedUntil (see that field's own comment) is
	-- active -- cannot throw a Basic or Heavy attack, but every other action (Block/Parry/Dash/
	-- Sprint/LockOn) still works.
	Disarmed: boolean,
	-- Committed to an action -- see CombatState.attackEndsAt in CombatSystem.lua. Despite the name,
	-- this covers more than a swing's windup/active/recovery: a dash's brief post-window recovery
	-- also sets attackEndsAt (the same shared commitment lock every action already respects), so
	-- this reads true during that recovery too. Cannot attack, block, or dash again while true.
	Attacking: boolean,
	-- True while the player is holding Sprint (CombatState.sprinting) -- intent, not effect: a raised
	-- WalkSpeed only actually applies when combat state permits it (see onHeartbeat). Always false for
	-- a training bot's snapshot; bots have no sprint/dash movement state (BotState) yet, which is the
	-- Reposition no-op TrainingBotWeights below still documents as awaiting movement AI.
	Sprinting: boolean,
	-- General-purpose "still fighting" signal (CombatState.inCombatUntil) -- refreshed on throwing/
	-- landing/receiving an attack, blocking, or an air-tech escape, independent of which specific
	-- action caused it. Not itself a legality gate for anything today; a pure read-only signal any
	-- current or future system can consult (unlike Attacking above, which is narrowly scoped to a
	-- single swing/dash's own commitment window).
	InCombat: boolean,
}

-- One stage of a melee swing's hitbox (Constants.Combat.Weapons[weaponId].Stages.Basic/Heavy
-- entries), consumed by
-- both CombatSystem.lua (attack-request validation, per-hit resolution) and
-- Server/Combat/HitboxResolver.lua (the oriented-box sampling/sweep itself). Defined here rather
-- than locally in either module because it's genuinely the static-data shape Constants.lua's
-- tables are authored in AND the runtime shape both consumers pass around -- a real shared
-- boundary, not a single module's own API surface (contrast HitboxResolver.SwingConfig, which
-- stays local to that module since it's only that module's own call shape).
export type HitboxAttackDefinition = {
	DebugName: string,
	-- Seconds after the request is accepted before the hitbox can register a hit (telegraph).
	WindupSeconds: number,
	-- Seconds the hitbox is live and sampled for overlaps, starting right after WindupSeconds.
	ActiveSeconds: number,
	-- Seconds of post-active endlag with no hitbox sampling. Tuning expectation (not enforced by
	-- code): Cooldown should be >= WindupSeconds + ActiveSeconds + RecoverySeconds, otherwise a new
	-- swing can start while the previous one's recovery hasn't finished.
	RecoverySeconds: number,
	-- Oriented box dimensions, in studs, passed directly to Workspace:GetPartBoundsInBox.
	Size: Vector3,
	-- Relative to the attacker's HumanoidRootPart CFrame, recomputed fresh every sample so the box
	-- follows the attacker's current position/facing during the active window (e.g. CFrame.new(0,
	-- 0, -3) sits 3 studs in front of the attacker).
	Offset: CFrame,
	Damage: number,
	PostureDamage: number,
	-- Minimum seconds between the start of this attack category's swings (see RecoverySeconds).
	Cooldown: number,
	-- Optional second validation layer beyond the box itself -- nil skips the arc check entirely
	-- (the box's own Size/Offset already constrains reach directionally).
	ArcDegrees: number?,
	-- Optional cap on distinct targets a single swing can land a hit on. nil = unlimited (every
	-- valid target the box overlaps gets hit, still capped at one hit each).
	MaxTargets: number?,
}

-- Result of DevMenu_SpawnDummy (a RemoteFunction, not a RemoteEvent -- the client needs to know
-- immediately whether its request was accepted, matching a request/response shape better than
-- combat's fire-and-forget remotes). Reason is populated only when Success is false, e.g.
-- "NotAuthorized" -- see DevMenuSystem.lua for the full set of reasons it can return.
export type DevMenuSpawnDummyResult = {
	Success: boolean,
	Reason: string?,
}

-- Client-only input remapping (Client/Input/KeybindManager.lua). Crosses no network boundary --
-- the server never needs to know what key was pressed, only the resulting request remote -- but
-- lives here per this file's own header ("shared types... imported, never redefined locally")
-- since both Constants.lua (Constants.Keybinds.Defaults) and every input-consuming client module
-- (CombatClient.lua, DevMenuClient.lua) need the same shape.
-- "Block" covers both blocking and parrying -- CombatSystem.lua's handleBlockStart treats every
-- accepted press as a timed block (a short parry window opens at press, holding past it is a plain
-- block), so there is no separate "Parry" action to bind. "Dash" fires the neutral-game
-- positioning burst (see CombatSystem.lua's handleDashRequest) -- a forward-resolved Dash can also
-- throw its own DashPunch/DashHit attack (CombatClient.lua's double-tap-W trigger fires the same
-- request with a flag set). "ShiftLock" toggles the custom shift-lock camera mode (Client/Camera/
-- ShiftLockCamera.lua) -- a camera behavior, not a combat request; it's the one action here that
-- never fires a remote. "Sprint" is a held neutral-game movement state (start/stop, like Block).
-- "SwapWeapon" fires RequestSwapWeapon (Constants.Combat.Weapons) -- a one-shot toggle between the
-- two weapon slots, the same fire-and-forget shape as Dash/Sprint. "Slide" fires RequestSlide
-- (CombatSystem.lua's handleSlideRequest) -- chained off Sprint, not a standalone press like Dash:
-- the client only even fires it while its own Sprint key is currently held, and the server
-- independently re-checks CombatState.sprinting regardless of what the client believes. "Feint"
-- fires RequestFeint (CombatSystem.lua's handleFeintRequest) -- cancels the player's own Basic/
-- Heavy/Finisher/AirSlam swing while it's still in its telegraph, before the hitbox goes active;
-- see FeintPerformedPayload's own header for the full mechanic.
export type KeybindAction =
	"BasicAttack"
	| "Block"
	| "HeavyAttack"
	| "LockOn"
	| "Dash"
	| "Sprint"
	| "ShiftLock"
	| "DevMenuToggle"
	| "SwapWeapon"
	| "Slide"
	| "Feint"
	-- Opens the player-facing bug report form (Client/UI/Screens/BugReport/init.lua via
	-- Client/BugReport/BugReportClient.lua) -- unlike every action above, this fires no combat
	-- remote and has no server-side legality check of its own; it's a pure client-side panel
	-- toggle, the same "never fires a remote" carve-out this file already documents for
	-- "ShiftLock".
	| "OpenBugReport"

-- Exactly one of KeyCode/UserInputType is populated -- KeyCode for ordinary keyboard keys,
-- UserInputType for inputs with no KeyCode equivalent (Roblox only reports mouse buttons via
-- UserInputType, e.g. Enum.UserInputType.MouseButton1, never a KeyCode).
export type Keybind = {
	KeyCode: Enum.KeyCode?,
	UserInputType: Enum.UserInputType?,
}

-- Training bots (Server/Systems/TrainingBotSystem.lua) -- AI-controlled practice opponents,
-- distinct from the static training dummy (which never acts). ai-design.md's "Training bots"
-- section is the canonical spec; ParryOnly doesn't map to a separate weighted action the way the
-- others do (CombatSystem.lua's handleBlockStart merged Block and Parry into one input for real
-- players), so it's a timing BEHAVIOR on the Block weight, not its own action -- see
-- TrainingBotSystem.lua's header for the full reasoning. This repo has no pathfinding/movement-AI
-- infrastructure yet (see Reposition below), which is also why bots have no dash/dodge AI at all.
export type TrainingBotPresetName =
	"AttackOnly"
	| "BlockOnly"
	| "ParryOnly"
	| "FullFight"
	| "Aggressor"
	| "Turtle"
	| "Custom"

-- Relative weights (not probabilities -- don't need to sum to 1), consumed by
-- TrainingBotSystem.lua's decision loop. Reposition exists for forward compatibility with
-- ai-design.md's full action model but is a documented no-op until real movement AI exists.
export type TrainingBotWeights = {
	Attack: number,
	Block: number,
	Parry: number,
	Reposition: number,
}

-- Result of DevMenu_SpawnTrainingBot (a RemoteFunction -- same request/response reasoning as
-- DevMenuSpawnDummyResult above).
export type DevMenuSpawnBotResult = {
	Success: boolean,
	Reason: string?,
}

-- Result of DevMenu_SetTargetHealth / DevMenu_SetTargetGodmode / DevMenu_SetTargetFlight
-- (RemoteFunctions -- same request/response reasoning as DevMenuSpawnDummyResult above). One
-- shared shape for all three admin actions -- they succeed/fail identically (NotAuthorized/
-- RateLimited/NoTarget/InternalError), nothing about the result differs enough to warrant three
-- near-identical types.
export type DevMenuActionResult = {
	Success: boolean,
	Reason: string?,
}

-- Hitbox timing tuning (Server/Combat/HitboxTuning.lua, DevMenu_ListHitboxStages/
-- DevMenu_AdjustHitboxTiming/DevMenu_ResetHitboxStage) -- a Studio-only LIVE tuning tool, not part
-- of the combat trust model: it lets an authorized admin nudge a swing's real
-- Windup/Active/RecoverySeconds while playtesting and immediately feel the result, without
-- restarting the session -- see HitboxTuning.lua's own header for why an in-place Constants
-- mutation takes effect on the very next (or even an already in-flight) swing. "Finisher" is a
-- single stage (not an array), so StageIndex is 0 for it; Basic/Heavy use a 1-based array index.
export type HitboxStageCategory = "Basic" | "Heavy" | "Finisher"
export type HitboxTimingField = "WindupSeconds" | "ActiveSeconds" | "RecoverySeconds"

export type HitboxStageInfo = {
	WeaponId: WeaponId,
	Category: HitboxStageCategory,
	StageIndex: number,
	DebugName: string,
	WindupSeconds: number,
	ActiveSeconds: number,
	RecoverySeconds: number,
}

-- Result of DevMenu_ListHitboxStages -- every tunable stage across both weapons, in a stable order
-- (HitboxTuning.ListStages), fetched ONCE by DevMenuClient.lua and cached client-side; every later
-- Adjust/Reset response (DevMenuHitboxStageResult below) only ever carries back the ONE stage that
-- changed, never a full re-fetch.
export type DevMenuListHitboxStagesResult = {
	Success: boolean,
	Stages: { HitboxStageInfo }?,
	Reason: string?,
}

-- Result of DevMenu_AdjustHitboxTiming / DevMenu_ResetHitboxStage -- same request/response
-- reasoning as DevMenuSpawnDummyResult, carrying back the ONE updated stage's new values so the
-- client can refresh its display without a second round trip.
export type DevMenuHitboxStageResult = {
	Success: boolean,
	Stage: HitboxStageInfo?,
	Reason: string?,
}

-- Standalone-attack live tuning (Server/Combat/HitboxTuning.lua's ListStandaloneAttacks/
-- AdjustStandaloneField/ResetStandaloneAttack, DevMenu_ListStandaloneAttacks/
-- DevMenu_AdjustStandaloneField/DevMenu_ResetStandaloneAttack) -- the same live-tuning idea as
-- HitboxStageInfo above, for the attacks that AREN'T a weapon combo stage (DashPunch/DashHit,
-- CombatSystem.lua's handleDashRequest; AirSlam, handleAirSlamRequest) and so don't fit that type's
-- (WeaponId, Category, StageIndex) key -- these are keyed by name instead. Also exposes
-- OffsetForwardStuds, which the weapon-stage tool deliberately does NOT (HitboxTuning.lua's own
-- header: "Scoped to TIMING only") -- these attacks' hand-tracked hitbox position (HitboxResolver.
-- SwingConfig.AttackerTrackedPart) was exactly what needed hands-on playtesting to dial in, so this
-- tool's scope is deliberately wider than the weapon-stage one.
export type StandaloneAttackName = "DashPunch" | "DashHit" | "AirSlam"
export type HitboxStandaloneField = "WindupSeconds" | "ActiveSeconds" | "RecoverySeconds" | "OffsetForwardStuds"

export type HitboxStandaloneInfo = {
	Name: StandaloneAttackName,
	DebugName: string,
	WindupSeconds: number,
	ActiveSeconds: number,
	RecoverySeconds: number,
	-- Studs the hitbox is nudged forward from its tracked-part origin (positive = further in front
	-- of the attacker) -- see HitboxTuning.lua's offsetForwardStuds for the CFrame<->number
	-- conversion, and that function's own header for why it assumes a pure-translation Offset.
	OffsetForwardStuds: number,
}

-- Result of DevMenu_ListStandaloneAttacks -- both tunable attacks, fetched ONCE by
-- DevMenuClient.lua and cached client-side, same "fetch once, cache, patch from Adjust/Reset
-- responses" shape as DevMenuListHitboxStagesResult.
export type DevMenuListStandaloneAttacksResult = {
	Success: boolean,
	Attacks: { HitboxStandaloneInfo }?,
	Reason: string?,
}

-- Result of DevMenu_AdjustStandaloneField / DevMenu_ResetStandaloneAttack -- same
-- request/response reasoning as DevMenuHitboxStageResult.
export type DevMenuStandaloneAttackResult = {
	Success: boolean,
	Attack: HitboxStandaloneInfo?,
	Reason: string?,
}

-- Live flight-tuning field names (Server/DevMenu/FlightTuning.lua, DevMenu_ListFlightTuning/
-- DevMenu_AdjustFlightTuning/DevMenu_ResetFlightTuning) -- a CURATED subset of Constants.Flight's own
-- fields worth exposing to hands-on playtesting, same scoping call HitboxTuning.lua makes for
-- Windup/Active/RecoverySeconds rather than a general Constants editor. Deliberately excludes fields
-- with no "feel" ambiguity to dial in (e.g. DefaultCollideMode, the AnimationIds/Sound tables).
export type FlightTuningFieldName =
	"CruiseSpeed"
	| "BoostSpeedMultiplier"
	| "Acceleration"
	| "BoostAcceleration"
	| "Deceleration"
	| "VerticalSpeedFraction"
	| "MaxBankAngleDegrees"
	| "MaxPitchAngleDegrees"
	| "BankTurnRateSensitivity"
	| "TakeoffBurstUpSpeed"
	| "TakeoffBurstForwardSpeed"
	| "HoverBobAmplitudeStuds"
	| "SoftLandingSpeedThreshold"
	| "HardLandingSpeedThreshold"
	| "SonicBoomSpeedThreshold"

export type FlightTuningInfo = {
	Field: FlightTuningFieldName,
	DisplayName: string,
	Value: number,
}

-- Result of DevMenu_ListFlightTuning -- every tunable field, fetched ONCE by DevMenuClient.lua and
-- cached client-side, same "fetch once, cache, patch from Adjust/Reset responses" shape as
-- DevMenuListHitboxStagesResult.
export type DevMenuListFlightTuningResult = {
	Success: boolean,
	Fields: { FlightTuningInfo }?,
	Reason: string?,
}

-- Result of DevMenu_AdjustFlightTuning / DevMenu_ResetFlightTuning.
export type DevMenuFlightTuningResult = {
	Success: boolean,
	Field: FlightTuningInfo?,
	Reason: string?,
}

-- Bug Report feature (Server/Systems/BugReportSystem.lua owns Category/Status/Record and the
-- public submit remote; DevMenuSystem.lua owns the two admin-facing Result wrappers below and
-- the "Reports" tab that consumes them -- same ownership split every other admin action in this
-- file already follows). ReporterUserId/ReporterName/CreatedAt/PlaceId/JobId/Position are always
-- derived server-side in BugReportSystem.Submit -- never accepted as client-sent values, even
-- though they're not gameplay-critical, because "server owns truth" applies here too.
export type BugReportCategory = "Bug" | "Exploit" | "Suggestion" | "Other"
export type BugReportStatus = "Open" | "Resolved" | "Dismissed"

export type BugReportRecord = {
	Id: string, -- HttpService:GenerateGUID(false); also the DataStore key in both stores
	ReporterUserId: number,
	ReporterName: string,
	Category: BugReportCategory,
	-- Already run through TextService:FilterStringAsync/GetNonChatStringForBroadcastAsync at
	-- submit time -- BugReportSystem never stores the raw client-typed text.
	Description: string,
	CreatedAt: number, -- os.time(), server clock
	PlaceId: number,
	JobId: string,
	-- nil if the reporter had no Character/HumanoidRootPart at submit time -- a missing position
	-- never rejects the report itself, see BugReportSystem.Submit.
	Position: Vector3?,
	Status: BugReportStatus,
	StatusUpdatedAt: number?,
	StatusUpdatedByUserId: number?,
}

-- Result of BugReport_Submit (RemoteFunction -- same "client needs an immediate answer" shape as
-- DevMenuSpawnDummyResult). ReportId lets the client show a confirmation/reference id on success.
export type BugReportSubmitResult = {
	Success: boolean,
	Reason: string?,
	ReportId: string?,
}

-- Which page BugReportSystem.ListReports should return. "First" (re)starts this admin's
-- server-held DataStorePages session; "Next" advances it -- see BugReportSystem's own header for
-- why the DataStorePages object itself can never cross this remote.
export type BugReportListCursorMode = "First" | "Next"

-- Result of DevMenu_ListBugReports (RemoteFunction). HasMore is meaningful only when Success is
-- true -- it reflects whether calling again with "Next" is worth doing.
export type DevMenuListBugReportsResult = {
	Success: boolean,
	Reason: string?,
	Reports: { BugReportRecord }?,
	HasMore: boolean?,
}

-- Result of DevMenu_UpdateBugReportStatus (RemoteFunction) -- carries back the one updated
-- record, same "return just what changed" shape as DevMenuHitboxStageResult.
export type DevMenuUpdateBugReportStatusResult = {
	Success: boolean,
	Reason: string?,
	Report: BugReportRecord?,
}

-- Teleportation / character-utility / server-wide admin actions -- every one of these reuses
-- DevMenuActionResult (defined above) for its RemoteFunction result, the same "nothing about the
-- result differs enough to warrant a near-identical type" reasoning that comment already gives for
-- SetTargetHealth/Godmode/Flight/FlightCollide. ShutdownServer's first (arming) press also returns
-- DevMenuActionResult with Reason = "ConfirmationRequired" -- not a distinct type, just another
-- Reason string for DevMenuClient.lua to special-case in its own describeX function.

-- Broadcast Announcement (DevMenu_Announcement, a RemoteEvent fired to EVERY client -- see that
-- remote's own header in Constants.lua). "Warning" is used for the Shutdown Server countdown;
-- "Info" for a plain admin broadcast.
export type DevMenuAnnouncementKind = "Info" | "Warning"

-- Payload of the DevMenu_Announcement RemoteEvent (broadcast to every client) --
-- Client/Announcement/AnnouncementClient.lua renders it as a banner (Kind picks the accent color).
export type DevMenuAnnouncementPayload = {
	Kind: DevMenuAnnouncementKind,
	Message: string,
}

-- Player roster ("Players" tab, DevMenu/init.lua) -- one entry per Players:GetPlayers() at fetch
-- time, RemoteFunction (fetch-on-open, not push -- see DevMenu_ListPlayers's own Constants.lua
-- comment). Snapshot is nil only if CombatSystem has no state for that Player yet (a brand-new join
-- before its own PlayerAdded handler has run) -- see CombatSystem.GetCombatState's own nil contract.
export type PlayerRosterEntry = {
	UserId: number,
	Name: string,
	Snapshot: CombatSnapshot?,
	Ping: number,
	-- ModerationSystem.IsMuted(UserId) at fetch time -- lets the "Players" tab's Mute button reflect
	-- real server state instead of a locally-guessed toggle, same "read real state, don't guess"
	-- precedent as DevMenuClient.watchTarget's Godmode/Flight Attribute tracking.
	Muted: boolean,
	-- ModerationSystem.IsSuspectedCheater(UserId) at fetch time -- same "read real state, don't
	-- guess" contract as Muted above, for the roster row's Flag-Suspected-Cheater action.
	SuspectedCheater: boolean,
}

-- Result of DevMenu_ListPlayers (RemoteFunction).
export type DevMenuListPlayersResult = {
	Success: boolean,
	Reason: string?,
	Players: { PlayerRosterEntry }?,
}

-- Suspected-cheater manual flagging (Server/Systems/ModerationSystem.lua, DevMenu_SetSuspectedCheater)
-- -- a REVERSIBLE toggle (mirrors Mute's reversibility, unlike Ban's one-way permanence) backed by
-- its own DataStore record per UserId, overwritten on re-flag rather than accumulating history.
-- "Manual" is an admin acting from the "Players" tab roster row (the only source this pass wires up);
-- "System" is reserved for a future automated-detection pipeline that doesn't exist yet -- see
-- Confidence/ReasonCode below, both of which stay nil until that pipeline is designed.
export type SuspicionSource = "Manual" | "System"

export type SuspicionRecord = {
	UserId: number,
	FlaggedAt: number,
	-- The flagging admin's UserId for a "Manual" flag; nil for a "System" flag with no individual
	-- admin behind it.
	FlaggedByUserId: number?,
	Reason: string,
	Source: SuspicionSource,
	-- Always nil this pass -- reserved for a future automated-detection pipeline's confidence score.
	Confidence: number?,
	-- Always nil this pass -- reserved for that same future pipeline's machine-readable reason code.
	ReasonCode: string?,
}

-- Result of DevMenu_GetSidebarStats (RemoteFunction) -- fetched eagerly at Sidebar mount (same "pay
-- one round trip even if the admin never looks" trade-off ListPlayers/ListBugReports already
-- accept) and re-fetched after a successful Flag/Unflag action. BugReportOpenCount/
-- SuspectedCheaterCount are each an in-memory counter maintained entirely by their owning System
-- (BugReportSystem.GetOpenCount / ModerationSystem.GetSuspectedCheaterCount) -- DevMenuSystem only
-- combines the two into one response so the Sidebar pays a single round trip instead of two.
export type DevMenuSidebarStatsResult = {
	Success: boolean,
	Reason: string?,
	BugReportOpenCount: number?,
	SuspectedCheaterCount: number?,
}

-- First-time-player onboarding / character creation (Server/Systems/CharacterCreationSystem.lua,
-- Client/Onboarding/OnboardingClient.lua). A first-time player is detected purely by
-- `profile.raceId == nil` -- no new boolean flag on PlayerProfile -- so these three types are the
-- entire network surface this feature needs.

-- Result of CharacterCreation_GetOnboardingState (RemoteFunction, no payload). Client/Main.client.lua
-- calls this before UI.Mount() -- see that file's own header for the boot-order reasoning. This is
-- also the request that triggers this SESSION's first Player:LoadCharacter() call (StarterPlayer.
-- CharacterAutoLoads = false, default.project.json) for every player, onboarding or not; see
-- CharacterCreationSystem.lua's header for the full contract.
export type CharacterCreationOnboardingStateResult = {
	NeedsOnboarding: boolean,
}

-- Payload of CharacterCreation_Finalize (RemoteFunction) -- every field stays `unknown` here
-- deliberately (not RaceId/string/AttributeBlock) since this crosses the client/server trust
-- boundary and hasn't been validated yet; CharacterCreationSystem.ValidateRaceId/
-- ValidateAttributeBlock/ValidateDisplayName are what narrow these into real types, server-side,
-- regardless of what the client's own Confirmation screen already checked.
export type CharacterCreationFinalizePayload = {
	RaceId: unknown,
	DisplayName: unknown,
	Attributes: unknown,
}

-- Result of CharacterCreation_Finalize. Reason is populated only when Success is false (e.g.
-- "InvalidRaceId", "AttributeBudgetInvalid", "InvalidDisplayName", "TransformFailed") -- see
-- CharacterCreationSystem.lua's handleFinalize for the full set. The client's Confirmation screen
-- loops/retries on Success = false rather than stranding the player (OnboardingClient.lua), the same
-- reject-and-retry UX BugReportClient.lua already establishes for BugReport_Submit.
export type CharacterCreationFinalizeResult = {
	Success: boolean,
	Reason: string?,
}

return Types
