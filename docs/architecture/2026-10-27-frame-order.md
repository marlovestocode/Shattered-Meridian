# Frame order and presentation owners (W10-W11, 2026-10-27)

## What landed (no behaviour change)

`Client/Config/FrameOrder.lua` names every client RenderStep slot, with today's exact values and one line per slot saying what it
reads that an earlier slot wrote. All 19 `BindToRenderStep` calls take their priority from `FrameOrder.Priority(name)`.
`Tests/Client/FrameOrder.spec.lua` fails on a clash that is not in `KNOWN_CLASHES`, and on a row that no longer clashes (so a fix
deletes its row). `scripts/cohesion-report.py`'s `shared_render_priority` counts the clashes plus any binding that bypasses the
table: 7 today.

## The four clashes, and the proposed fix for each (REQUIRES PLAYTEST)

**Update 2026-10-27:** the three camera clashes below were settled by the camera pass. The camera band now has one value
per slot; see `docs/architecture/2026-10-27-camera-motion.md`. ShiftLock* and LockOn are now `CombatCamera*`, and
ParkourCamera's roll went to `CameraRotation`. Only the Character+1 pose row remains.

Inside one priority value the engine's order is unspecified. Each fix below gives the slots distinct values in `FrameOrder.lua`
and deletes the `KNOWN_CLASHES` row.

| Value | Slots | Proposed order | Why | Watch for |
|---|---|---|---|---|
| Camera-2 | ShiftLockOffset, CameraShakeUndo | see the full camera band below | the shake must be removed before anything reads the camera | shoulder offset jitter while shaking |
| Camera-1 | LockOn, CameraOffsetComposer | see the full camera band below | lock-on aims before the composer applies the offsets | lock-on target drift while shift-locked |
| Camera+1 | BlimpCamera, FlightCamera, ShiftLockCamera, FOVOffset | FlightCamera / BlimpCamera +1 (mutually exclusive modes), ShiftLockCamera +2 (copies the final yaw), FOVOffset +3, then CameraShake +4 and ParkourCamera +5 | the body must copy the yaw AFTER every camera mode has written it | shift lock while flying or piloting; FOV punches during a blimp kick |
| Character+1 | BlimpPose, BoatPose, HitFlinchPose | BlimpPose / BoatPose +1 (never both: one mount), HitFlinchPose +2, GuardStrainPose +3, GrabHoldPose +4 | an absolute vessel pose must run before an additive flinch, or the flinch is overwritten | a pilot taking a hit |

**Proposed full camera band** (one distinct value each, in this order): CameraShakeUndo Camera-5, CameraFollow Camera-4,
ShiftLockOffset Camera-3, LockOn Camera-2, CameraOffsetComposer Camera-1, then the engine's camera, then FlightCamera /
BlimpCamera Camera+1 (mutually exclusive modes; one slot is fine only if the spec's clash rule gets a "never both live" exception,
otherwise +1 and +2), ShiftLockCamera +3, FOVOffset +4, CameraShake +5, ParkourCamera +6.

## W11 presentation owners -- escalations, not built

The plan builds each only if it removes the flag peepholes with no behaviour change. None can be shown to without a playtest, so
none was built; the facts and the options are here.

- **P1. Camera CFrame has six writers** (BlimpCamera, FlightCamera, ShiftLockCamera, ParkourCamera, CameraShake, PlacementCamera)
  that exclude each other through flags (`Flying`, `Mounted`, `RootControlLocked` reads in ShiftLockCamera). Option A: a `CameraRig`
  with mode claims (Follow / ShiftLock / Flight / Blimp / Scriptable), the shape of `RootControl`, and shake as an additive layer.
  Effort L; touches every camera file; the clash table above must be settled first. Option B: keep the flags; the FrameOrder table
  now at least states the order.
- **P2. Absolute joint writers run around TransformLayer.** GrabHoldPose and VesselArmPose/VesselPilotPose write `Motor6D.Transform`
  absolutely; HitFlinchPose composes additively onto RootJoint, which VesselPilotPose also writes. Option A: TransformLayer gains
  absolute claims ranked above additive layers. Effort M. Symptom today: none reported; inferred from source.
- **P3. Three animators bypass AnimationManager** (CombatAnimator, EmoteAnimator, FlightAnimator; `load_animation_bypass` = 6), and
  AnimationManager's header cites `Client/FX/LocalAnimator.lua`, which does not exist. Option A: run the plan's spike, then migrate
  Emote -> Flight -> Combat onto LocalAnimator layers. Option B: narrow AnimationManager's header to name the three exceptions and
  why (correct today, effort S). The header is still false; the user should pick.

## Server tick (W10 server half) -- escalation

Combat steps through `CombatTick.PHASES`; RunSystem and ParkourSystem each connect their own Heartbeat; `GameplayEvents.HeartbeatTick`
has its subscribers. Their relative order today is connection order, which follows `Main.server.lua`'s boot order. A `ServerTick`
with phase groups (Movement, Combat, World) would DEFINE that order rather than inherit it -- a real change to which System sees
which frame's state first (MovementGuard reads RunSystem's speed, for one). Option A: build ServerTick with Movement -> Combat ->
World, matching today's boot order, and playtest movement checks under combat. Effort M. Not built.

## Playtest checklist for this spine

walk, run, armed run, armed idle with a drawn weapon, each emote, take off / cruise / boost / land, hit-stop during each, die during
each, respawn, lock-on while shift-locked, a blimp pilot taking a hit, an intro camera after respawn.
