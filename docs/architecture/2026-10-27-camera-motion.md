# The camera stack: movement response, combat manager, blimp overhaul (2026-10-27)

## Who owns what

**Four composers.** Each one is the only writer of one camera property. Everything else writes through a named slot.

| Composer | Property | Slots today |
|---|---|---|
| `FX/FOVOffset` | `Camera.FieldOfView` | Sprint, run stage, `MotionSpeed`, `Flight`, `Blimp`, parkour slide/mantle, punches |
| `FX/CameraOffsetComposer` | `Humanoid.CameraOffset` | `Follow`, `ShiftLock`, `Motion`, `Flight`, `Blimp`, `Parkour` |
| `FX/CameraShake` | transient rotation (one decaying impact shake) | — |
| `FX/CameraRotationComposer` (new) | continuous rotation (pitch, yaw, roll) | `MotionLean`, `ParkourTilt`, `Flight` (bank), `Blimp` (roll, sway, pitch) |

**Writers.**

| Module | Job | Writes through |
|---|---|---|
| `Camera/CameraFollow` | the view trails an accelerating body | offset |
| `Camera/CameraMotion` | lean, pull-back, speed FOV, landing compression from measured velocity (`Shared/CameraMotionMath`, `CameraConstants.Motion`) | offset, FOV, rotation, shake |
| `Camera/CombatCamera` (was `ShiftLockCamera`) | **the combat camera manager**: shift lock's shoulder, mouse lock and body turn, and lock-on's hold on the view (`Shared/CombatCameraMath`) | offset; the look (lock-on, on purpose); the body's yaw |
| `Camera/FlightCamera` | flight chase, zoom, bank | offset, FOV, rotation |
| `Camera/BlimpCamera` | aboard-a-blimp roll, sway, pitch, surge, bob, rumble, zoom (`Shared/Blimp/BlimpCameraMath`) | offset, FOV, rotation |
| `Parkour/ParkourCamera` | slide framing, wall tilt, traversal punches | offset, FOV, rotation, shake |
| `Combat/LockOnController` | lock-on target, break rules, marker; **no camera writes**. `Step()` hands CombatCamera the aim point | — |

## The camera band (FrameOrder, one value per slot)

```
Camera-9 CameraRotationUndo   last frame's continuous rotation off (applied last, so off first)
Camera-8 CameraShakeUndo      last frame's shake off
Camera-7 FlightCamera         sets slots
Camera-6 BlimpCamera          sets slots
Camera-5 CameraMotion         reads the clean look and root velocity, sets slots
Camera-4 CameraFollow         sets the trail
Camera-3 CombatCameraShoulder sets the shoulder from the clean yaw
Camera-2 CombatCameraAim      lock-on pulls the clean look
Camera-1 CameraOffsetComposer writes CameraOffset
Camera   (engine camera scripts)
Camera+1 CombatCameraBody     body copies the camera yaw, mouse lock
Camera+2 FOVOffset            writes FieldOfView
Camera+3 CameraShake          shake on
Camera+4 CameraRotation       continuous rotation on
```

The three camera clashes `KNOWN_CLASHES` listed are gone. `cohesion-report` `shared_render_priority` dropped from 7 to 2, and the ceiling was updated. Only the Character+1 pose clash is left.

## What was broken, and is fixed

- **The blimp camera kept spinning in turns and drifting in climbs.** It multiplied pitch, yaw and roll onto
  `Camera.CFrame` at Camera+1 and never removed them. The default camera reads its look back off that CFrame, so the
  sway and pitch were re-applied on top of themselves every frame. It now goes through `CameraRotationComposer`, which
  undoes exactly. Its step also moved ahead of the offset composer, because the offset was a frame late. Its springs now use
  `FlightMath.SpringAdvance` (sub-stepped), so a turn rolls the same at 30 and 144 fps: within 0.3%, where it was 3% before.
- **Flight's bank** and **the wall-run tilt** were also direct `Camera.CFrame` multiplies. A pure roll does not move the
  look, but one left under the shake made the shake's undo rotate about the wrong axes. Both now go through the composer.
- **FlightCamera's offset was a frame late** (Camera+1), and **it leaked on death**: `OnCharacterRemoving` set
  `engaged = false` without clearing its slots or restoring the occlusion mode. It now disengages properly.
- **Two angle helpers existed twice.** `CombatTargets.YawOf`/`AngleDelta` and ShiftLock's inline wrap are now
  `FlightMath.YawFromFlatDirection`/`AngleDelta`.
- **The spring sub-stepper was private** to CameraMotionMath. It is now `FlightMath.SpringAdvance`/`SpringPeakFactor`,
  beside `SpringStep`, used by CameraMotion and the blimp.

## Migration list (the CombatCamera rebuild)

| Consumer | What happened |
|---|---|
| `Camera/ShiftLockCamera.lua` | renamed `Camera/CombatCamera.lua` (`git mv`). Behaviour kept; facing guards → `CombatCameraMath.BodyFacingHeld` |
| `Combat/LockOnController.lua` | `pullCamera` and its velocities moved to `CombatCameraMath.LockOnLook`; its render step was removed; `Step()` added |
| `Main.client.lua`, `ClientBootManifest` | boot `CombatCamera`; the camera section was regrouped (composers first) |
| `Emotes/EmoteWheelClient`, `DevTools/MoveEditor/PlacementCamera` | `CombatCamera.SetInputSuspended`, same API |
| `FrameOrder` | `ShiftLockOffset`/`LockOn`/`ShiftLockCamera` → `CombatCameraShoulder`/`CombatCameraAim`/`CombatCameraBody` |
| `scripts/cohesion-report.py` | restraint-read exemption renamed to `CombatCamera.lua`; `scripts/run-tests.lua` require list updated |
| `DebugConstants` | logger scope renamed |
| Specs | helm-controls owner tables, `StateFacingGates` comment |
| `FX/CameraRollComposer.lua` (built earlier today) | replaced by `CameraRotationComposer` (all axes); file and spec deleted |

Proven, not asserted: `Tests/Shared/CombatCameraMath.spec.lua` runs the old `pullCamera` arithmetic (verbatim, with the
old `YawOf`/`AngleDelta`) against `LockOnLook` over a 200-case corpus. It also runs the old yaw guards against
`BodyFacingHeld` over all 128 flag combinations.

## Movement response (CameraMotion)

| Channel | Physical input | Bound |
|---|---|---|
| Lean | lateral acceleration across the camera's right axis, past a deadzone, faded in with speed | 2 deg (full at 110 studs/s^2) |
| Pull-back | planar speed 24→46 studs/s, along the camera's flat back direction | 1 stud |
| Speed FOV | planar speed above sprint; downward speed above 60 | 7 + 4 deg |
| Landing | vertical speed lost in one frame (58→150 studs/s), underdamped dip; shake above severity 0.4 | 0.25→1.2 studs |

It suspends under `BodyRestraint`'s `CameraMotion` row (Mounted, Flying, RootLocked, Grabbed, Frozen), and it stands down for
first person, a non-Custom camera, death, or Settings → Camera effects off. The speed FOV, landing dip and wall-tilt roll
used to live privately in `ParkourCamera`.

## Tuning pass: calmer in a fight, parkour kept strong (2026-10-27)

The first pass read as too strong and disorienting in fast combat. Movement and combat came down; the parkour treatment
did not.

| Area | Was | Now |
|---|---|---|
| Lean (CameraMotion) | 3.5 deg, full at 80, damping 0.8 | 2 deg, full at 110, damping 0.9 |
| Pull-back (CameraMotion) | 20→46 studs/s, 1.6 studs | 24→46, 1 stud |
| Follow trail | 14/16 rad/s, lag 1.1/0.8 studs | 16/18, lag 0.8/0.6 |
| Sprint FOV | -3 deg | -2 deg |
| Lock-on pull | yaw 14 / pitch 9, close-range 0.4 | 11 / 7, close-range 0.3 |
| Combat shake presets (FXConstants) | — | amplitude x0.7, duration x0.85 (per-move shakes name these) |
| Parry FOV punch | -4 / -8 | -2.5 / -5 |
| Per-press swing punch | -1.6 | -1 |
| Air-combo punches / shakes | 2.5/4/7/9, 0.02/0.03/0.06/0.05 | 1.5/2.5/4.5/5.5, 0.013/0.02/0.04/0.035 |

**Unchanged on purpose (the parkour camera):** ParkourCamera's wall tilt, slide framing, vault/dash/mantle punches and
`ParkourConstants.Shake`; CameraMotion's overspeed FOV (above sprint only), free-fall FOV and landing compression; the
movement presets `SlideStart` and `Roll`. Also unchanged: the shift-lock shoulder offset, and the blimp camera.

## Not done, on purpose

- **A persisted reduce-motion slider.** It needs a `Comfort` field and a profile-corpus update; the persisted shape is
  the user's call. `CameraConstants.Motion.Scale` holds per-channel multipliers in the meantime.
- **Lock-on shoulder framing.** Engaging the shoulder offset while locked on, without shift lock, would be a design change.
- **A vessel-generic camera.** Boats have no camera of their own. `BlimpCameraMath` reads `BlimpConstants` directly;
  making it a `Shared/Vessel` binding is the shape the vessel layer uses for everything else.
- **`DevCameraOcclusionMode`** is still saved and restored independently by FlightCamera and BlimpCamera. They are mutually
  exclusive by BodyRestraint, so the two never overlap today.
- Root velocity counts a moving platform as speed, and an anchored traversal (a mantle) has no velocity.

## Verification status

- `selene` is 0 errors; its 2 warnings are in an untouched `Inventory/init.lua`. `cohesion-report`, `check-client-boot`,
  `check-single-writers`, `check-endpoints` and `check-spec-literals` pass. Spec thresholds for CameraMotionMath and the
  blimp frame-rate case were checked against a Python port.
- **The TestEZ suite was not run** (Studio was open on the machine, and `run-in-roblox` would run inside it). **Nothing was
  playtested.**
- Playtest checklist: walk, sprint, strafe-start, reversal, an arc at sprint pace, jump landing (unfelt), 15- and 30-stud
  drops, knockback ending in a landing, ragdoll and air-combo hold (quiet), respawn mid-lean, shift lock, lock-on with and
  without shift lock (body faces the target only with shift lock), lock-on through a close brawl, emote wheel while
  shift-locked, wall-run, slide, flight take-off/bank/landing and dying mid-flight, a blimp turn held for 10 s (the view must
  NOT keep swinging), a climb, a telegraph kick, mount/dismount, an intro camera mid-flight, first person, Camera effects off
  mid-run, 30 and 144 fps.
