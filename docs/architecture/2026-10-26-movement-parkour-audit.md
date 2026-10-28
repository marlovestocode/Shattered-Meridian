# Movement and parkour audit (2026-10-26)

What the movement pipeline actually is, the defects found in it, and what was changed. Read before a large
movement change; re-verify a finding against source before restating it.

## 1. The pipeline as it exists

The brief that started this pass named `Server/Combat/Movement.lua`, `Server/Systems/CombatSystem.lua`,
`Server/Combat/CombatTypes.lua`, `Client/Combat/CombatClient.lua`, `Client/Combat/PredictionMirror.lua` and
`Tests/Combat/Movement.spec.lua`. **None of them exist.** The combat rewrite replaced them. What exists:

| Concern | Owner |
|---|---|
| Per-frame orchestration (gate → sample → probe → decide → commit → present) | `Client/Parkour/ParkourController.lua` (Heartbeat) |
| State machine (priority pre-emption, `Committed`, at most one transition per frame) | `Client/Parkour/StateMachine.lua` |
| 18 states (Idle, Walking, Sprinting, Jumping, Falling, Landing, WallLaunching, Sliding, Dashing, Evading, Mantling, Vaulting, WallRunning + kick phase, Leaping, LedgeHanging, LedgeLeaping, LedgeClimbing, CombatHeld) | `Client/Parkour/States/*`, registry and priority ladder in `States/init.lua` |
| Every raycast, budgeted per frame | `Client/Parkour/EnvironmentProbe.lua`; surface judgement in `Shared/Parkour/SurfaceLock.lua`; classification in `ObstacleClassifier.lua` |
| The one writer to the body (Humanoid / Velocity / Kinematic drive, external-impulse interrupts) | `Client/Parkour/ParkourMotor.lua` |
| Input buffering, coyote time, assists | `Client/Parkour/InputBuffer.lua`, `ParkourInput.lua` |
| Animation, camera, audio, VFX | `ParkourAnimator`, `ParkourCamera`, `FX/ParkourAudio`, `FX/MovementVFX` — all fed by the controller's `onTransition` |
| Sprint intent | `Client/Movement/RunController.lua` (pulled by the controller each frame) |
| Server: trust boundary, velocity-ownership window, momentum carry | `Server/Systems/ParkourSystem.lua` + pure `Shared/Parkour/ParkourValidation.lua` |
| Server: WalkSpeed resolver (single writer) | `Server/Systems/RunSystem.lua` |
| Cross-system seams | Humanoid Attributes: `ParkourVelocityOwned`, `ParkourActionOwned`, `ParkourFacingOwned`, `RootControlLocked`, `KnockbackUntil`, domain rule bitmask |
| Tunables | `Shared/Parkour/ParkourConstants.lua` (2.1k lines) |

The client simulates its own body (Roblox network ownership). The server cannot move a player's body. What it
does instead: it grants or refuses a velocity-ownership window per reported action, stands RunSystem down for it,
clamps the one client number that reaches gameplay (the exit-speed carry) against observed velocity, and flags
sustained implausible reports through `SuspicionLedger`. `MovementGuard` judges engaged players separately. That
trust model is stated in both server headers and is the right one; this pass kept it.

**No new mechanics were added.** Every candidate mechanic in the brief already exists as a state. The defects
were in how the framework meets the rest of the game.

## 2. Defects found and fixed

### D1. An End report could be refused, stranding WalkSpeed at 0
`ParkourValidation`'s own header says an End is a release and must never be refused. Two paths still refused one:
- `ParkourSystem` checked `RootControlLocked` and the air combo **before** the phase split. So a slide's End,
  sent on the frame a stagger parked the client in CombatHeld, was refused as `CombatRestricted`.
  `ParkourVelocityOwned` stayed up and RunSystem held WalkSpeed at 0 after the stagger ended, until the
  client watchdog's next retry or the window expiry.
- `Validate` ran its speed and claim-drift checks above the phase split. `interruptOwner` ends a slide carrying
  the knockback's planar speed, so a big launch produced an End past `MaxReportedSpeed`, and that End was refused.

**Fix:** every gate is now Start-only. The held-body/realm gate is the pure `ParkourValidation.Restrict` (specced).
Since an End is now always accepted, the **carry** is gated instead: an End that arrives while the body is
held elsewhere, or inside a `KnockbackUntil` allowance, closes the window and earns no carry. Otherwise a
launched player would get the launch's speed as a run-speed floor.

### D2. Client and server disagreed on "someone else holds this body"
The client parked in CombatHeld for six holds (RootControlLocked, Flying, Frozen, EmoteMovementLocked, air combo,
dead). The server refused a Start for two of them. **Neither read a realm's `Rooted` rule.** RunSystem zeroes
WalkSpeed for it, but Velocity and Kinematic states never read WalkSpeed, so a rooted player could still dash,
leap, slide or vault out, and could jump.

**Fix:** one predicate, `Shared/Parkour/ParkourOwnership.HeldElsewhere`, used by both sides, with `Rooted`
included (specced, lease-aware). **Deliberate behaviour decision:** `Rooted` now holds the whole body,
evade included. That matches RunSystem, which already puts it in the same tier as Grabbed and Frozen. Exempting
the evade would need a per-state gate in five or more CanEnters plus their route-1 paths. Reverse it there if
a realm should root but still allow the evade.

### D3. Four modules fought over the Humanoid's Jumping switch
`AttackInputClient` (launcher window), `GrabInputClient` (throw root) and `SwingRootClient` (locked swing)
each wrote `SetStateEnabled(Jumping, ...)` directly, and each put the jump back on its own schedule:
- If the launcher window lapsed during a locked swing, the attacker could jump out of the lock.
- If a locked swing ended inside the launcher window, Space hopped instead of acting as the launcher modifier.
- `Rooted` needed a fourth writer.

**Fix:** `Client/Movement/JumpGate.lua` is the single writer. It holds one named claim per owner, and the jump is
off while any claim is held: the client twin of `Server/Combat/RootControl`. All three writers moved, and
`SwingRootClient` gained the realm-root claim, which re-checks at the realm's lease end. `grep
SetStateEnabled(Enum.HumanoidStateType.Jumping` now finds only JumpGate.

### D4. Forced slope slides skipped every slide gate
Idle, Walking and Sprinting returned `"Sliding"` from `Update` on a slope ≥ `ForcedSlideAngleDegrees`. That is a
route-1 hand-off, which never asks `CanEnter`, so the slide cooldown, the combat gate and a realm's NoParkour were
all skipped. Inside a sealed realm this looped: the server refused the Start, the client fell back to Idle, and
Idle forced the slide again on the next frame. Separately, a surface sitting at the threshold cycled the slide
(Start/End reports) once per cooldown.

**Fix:** the three route-1 hand-offs are deleted. Sliding (priority 120) pre-empts the ground states through its
own `CanEnter`, which already accepted the forced case without a press. A forced slide now ends only below the
threshold minus `Slope.ForcedSlideExitHysteresisDegrees` (4°). Specced in `Tests/Parkour/ForcedSlide.spec.lua`.

### D5. Four modules snapshot-and-restored AutoRotate over each other
D3's bug class, on the body's turning instead of its jump. `ShiftLockCamera` (engaged), `ParkourMotor`
(while it owns the body), `SwingTracking` (turn-to-target and facing hold) and `GrabInputClient` (throw root)
each wrote `Humanoid.AutoRotate = false`, took a snapshot first and wrote it back afterwards. A snapshot is only
right if nothing wrote the property in between, and these four overlap:
- A grab throw is a swing. SwingTracking switched AutoRotate off, the throw captured that `false`, and the
  swing's end wrote `true` mid-clip. The thrower turned with their movement during a throw meant to root them.
- A swing that ended after the player engaged shift lock wrote `true` under it, so the Humanoid's turn fought
  shift lock's yaw write on every strafe until the next toggle.
- Disengaging shift lock mid-swing wrote `true` and dropped the swing's facing hold early.
- `ShiftLockCamera` had grown a `ParkourFacingOwned` falling-edge handler that re-asserted its own answer after
  parkour's restore, to repair one of these pairs. Whether that repair won depended on `SignalBehavior`.

**Fix:** `Client/Movement/TurnGate.lua` is the single client writer of AutoRotate: a named claim per owner, off
while any claim is held. The claim bookkeeping moved into `Client/Movement/HumanoidClaims.lua`, which
`JumpGate` now uses too (its API is unchanged). All four writers moved. The re-assert handler is deleted, and so
is `ParkourMotor.IsFacingHeldElsewhere`, which nothing called. `scripts/check-single-writers.py` now also fails any
`StarterPlayer` file other than its gate that writes `.AutoRotate =` or `SetStateEnabled(...Jumping...)`.
Specced in `Tests/Client/Movement/TurnGate.spec.lua` and `Tests/Parkour/ParkourMotor.spec.lua`.

## 3. Left alone, on purpose
- **Route-1 transitions skipping `CanEnter`** is the machine's documented contract; each route-1 site states the
  gates it needs. D4 removed the last forced-slide copies. `Dashing → Sliding` still skips the slide cooldown;
  a dash has its own 0.75 s cooldown, which bounds the chain.
- **`endAction` closes any open window regardless of kind.** With in-order delivery on one remote, End(prev)
  always precedes Start(next). Making it kind-strict would risk a strand to fix a case that cannot occur.
- **No server-side geometry validation** of vaults, wall-runs and so on. The server cannot see the client's
  probe and cannot move the body. Re-casting would either duplicate EnvironmentProbe or false-positive on replication lag.
  `MovementGuard` already judges engaged players' displacement.
- **Server-side AutoRotate writes** (`AdminActionSystem` flight, `TrainingBotSystem`'s bot bodies) are not
  TurnGate owners. Flight sets it from the server, and a client claim released during flight (for example,
  shift lock disengaging) can write `true` locally under it. That was true before D5 as well. Making flight a
  client owner is a small follow-up if it shows up in play.
- `ParkourConstants.lua` (2.1k lines) and `EnvironmentProbe.lua` (2k lines) are large, but not wrong because of it.

## 4. Studio-only verification (manual)
1. **Stagger mid-slide:** sprint, slide, get hit by a stagger. After the stun ends, you walk at once with no
   ~0.3 s freeze (D1).
2. **Launch mid-slide:** get launched by a heavy while sliding. On landing there is no burst of run speed (D1 carry gate).
3. **Rooted realm:** inside a realm with Rooted, Q/dash, leap, slide and Space all do nothing. When the realm ends,
   all of them work again with no respawn (D2/D3).
4. **Locked swing + launcher window:** B1, B2, then a LocksMovement move. Space does not hop during the lock; after
   the lock, Space is still the launcher modifier while the string is live (D3).
5. **Steep ramp:** walk onto a ramp just over 38°. It slides you; re-entering the ramp inside 0.45 s does not
   re-slide; standing at the 38° seam does not flicker. In combat (tagged), a steep ramp no longer forces a slide (D4).
6. **Grab throw turning (D5):** grab someone and throw them while holding a movement key sideways. The thrower
   does not turn toward the movement during the throw clip. Afterwards, they turn normally again.
7. **Shift lock across a swing (D5):** start an M1, engage shift lock before the hit lands, then strafe. The body
   stays on the camera's yaw without jitter. Disengage it mid-swing: the swing still holds its facing until the
   hit window closes.
8. **Shift lock across a traversal (D5):** engage shift lock, wall-run, and disengage it mid-run. After landing,
   the body turns toward the movement direction.
