# Combat smoothness pass: kickoff for the implementing session (2026-10-26)

You are implementing a smoothness pass on Shattered Meridian's combat and combat camera. Players say it feels
clunky and that the camera does things that make no sense. A review session (Opus 5.5) traced the camera
stack, the attack pipeline, the defence layer and the uncommitted work in progress. This document is what
that session found and checked. Your job is to fix what it lists, in the order it lists, and to verify each
fix.

Every claim below is labelled:

- **VERIFIED**: read in current source on 2026-10-26, with the file and line.
- **DERIVED**: follows from verified code plus documented engine behaviour, but nobody has measured it in
  Studio yet. Confirm it before you build on it. Each one says how.
- **DECISION**: the user has to choose. Do not pick for them. Ask, give your recommendation, and wait.

If something you read disagrees with this document, the source wins. Say so in your report. Do not make
it fit.

---

## 0. Read first, and the rules you work under

1. Invoke the `shattered-meridian-studio` skill before anything else. Load `combat-philosophy.md` and
   `software-architecture.md`.
2. Read `CLAUDE.md` in full, especially: the shared-module table, "Combat stack layering", "Extend, migrate,
   never fork" and "Toolchain". Those rules apply to everything here.
3. Read `docs/architecture/2026-10-25-deepwoken-combat-pass.md` and
   `docs/architecture/2026-10-25-cohesion-audit.md` §5 (Escalations). Items 4, 5 and 7 there are open user
   decisions. **They are not part of this pass.** Do not implement them unless the user tells you to.
4. **There is uncommitted combat work in the tree from another session, dated 2026-10-26.** Run `git diff --
   src/` before you touch anything. It contains: the close-time clash rule and clash posture cost
   (`DefenseSystem.lua`, `OutcomeResolver.lua`, `DefenseConstants.Clash`), `HitboxEngine.WindupRemaining` and
   `AttackStateMachine.GetWindupRemaining`, a clash animation slot (`WeaponDefenseAnimations.GetClash`,
   `DefenseClient`), a clamped parry facing snap (`DefenseClient.faceTowards`), `LockOnConstants.StepIn.
   MaxStepStuds` 2.4 → 1.6, and `AttackAnimations` `Basic:3` changed to the same clip as `Basic:1`, plus
   specs. **Build on it. Do not revert it.** Sections 1.1, 1.3, 1.4 and 4.2 below are review findings
   against it.
5. Never run `run-in-roblox` while the user has Studio open. Its plugin runs inside their session. Ask first.
6. One concern per commit, and a rename never rides along with structure. Commit only if the user has asked
   you to. Otherwise leave each concern as a clean, reviewable change and list them.
7. Wire payloads, remote names and Attribute names stay byte-identical unless the user decides otherwise.
   Every item below that needs a wire change is marked DECISION.

---

## 1. Defects (fix these first)

### 1.1 The parry facing snap aims at a point on the parrier's own body. With the uncommitted distance gate, it now almost never fires.

**VERIFIED.**

- `DefenseSystem.applyContact` sends the parrier's facing target as `contact.Report.ContactPosition` for a
  melee parry (`Server/Combat/Defense/DefenseSystem.lua`, the `notifyClient` call in the `kind == "Parried"`
  branch, around line 1122).
- `ContactPosition` is `part:GetClosestPointOnSurface(pose.Position)`, where `part` is a part of the
  **target**, which is the defender (`HitboxEngine.lua:514`, and the comment above it: "The point on the
  TARGET's surface nearest the hitbox origin"). The hurtbox is the root plus its direct-child BaseParts
  (CLAUDE.md, "One combat Heartbeat").
- So the parrier turns toward a point on its own torso or limbs. The direction is a rough proxy for the
  attacker's side at best.
- The uncommitted `DefenseClient.faceTowards` (`Client/Defense/DefenseClient.lua:520`) now returns early when
  the flat distance from the root to that point is at most `DefenseConstants.Presentation.
  ParryFacingMinDistanceStuds = 2.5` (`DefenseConstants.lua:488`). A point on your own R6 body is almost
  always inside that, so the melee snap is close to dead. Its own comment says it limits "the attacker
  position it turns toward", which is not what is sent.

**Fix.** Send the attacker's root position for a melee parry (`CharacterUtil.RootOf(contact.Attacker)`),
falling back to `ContactPosition` only if the attacker has no root. A projectile keeps
`projectile.SourcePosition`. Keep the uncommitted max-turn clamp and min-distance gate: both make sense once
the input really is the attacker. `predictor:NoteParryLanded()` must still run whether or not the snap turns
the body (it does today, because it sits after the `faceTowards` call).

**Test.** A spec showing a melee parry's push carries the attacker's root position. If the DefenseSystem
specs cannot observe the `StateChanged` payload, pull the "where does the parrier face" choice into a pure
function and test that, rather than skipping the test.

### 1.2 `CombatFacingOwned` has two client writers and no ownership. It can stay `true` forever, and then a shift-locked body stops turning with the camera.

**VERIFIED.**

- Writers: `SwingTracking.onAttackStarted` sets it, and `SwingTracking.finish` clears it unconditionally
  (`Client/Combat/SwingTracking.lua:84-95`, `116-148`). `DefenseClient.holdFacing` sets it after a parry and
  clears it `ParryFacingHoldSeconds` (0.3 s) later, **but skips the clear whenever
  `LocalCombatState.SwingEndsAt() > os.clock()`** (`DefenseClient.lua:501-518`), on the assumption that a
  swing's tracking window owns the Attribute then.
- That assumption fails whenever a swing runs without a tracking window. `SwingTracking.onAttackStarted`
  returns before setting anything when there is no target in the lock or the assist cone
  (`SwingTracking.lua:130`), for an air-combo move, and when `rotationOwnedElsewhere` is true.
- **Sequence that sticks it:** a parry lands, so the hold is set. Within 0.3 s the player throws a swing that
  is not tracked. The hold's delayed clear sees a swing running and returns. Nothing else ever clears it.
  `ShiftLockCamera` skips its yaw write while `combatFacingOwned` is true (`ShiftLockCamera.lua:379`), so
  under shift lock the body freezes at whatever angle it had. It stays frozen until some later tracked
  swing's `finish` happens to clear it, or the player respawns.
- **The reverse also happens:** if a tracked swing's `finish` runs inside a parry hold, it clears the hold
  early.

**Fix.** Make the facing hold a keyed claim with one publisher: owner → held, and the Attribute is true
while any owner holds a claim. That is the shape `Server/Combat/RootControl.lua` gives `RootControlLocked`
server-side. Put it in an existing client module that both writers already reach. `LocalCombatState` is
required by `AttackInputClient` and `DefenseClient`. Read its header to confirm the fit before you add to it.
Only create a new module if nothing existing owns the job, and justify it (CLAUDE.md, "Extend, migrate,
never fork"). Then move both writers onto it in the same change and delete the bare `SetAttribute` writes.
Consider a row for `CombatFacingOwned` in `scripts/check-single-writers.py`. Read the script first to see
whether it fits a client-written Attribute.

**Test.** A spec for the claim logic: two owners, either release order, and the Attribute clears only when
both have released.

### 1.3 The uncommitted close-time clash rule has no facing test. A defender hit from behind can "clash".

**VERIFIED** (uncommitted code).

- In `DefenseSystem.onHit` (around lines 972-983), a Clean melee hit becomes a clash candidate when the
  defender's swing opens within `Clash.WindowSeconds` (0.08 s), the defender has not taken a Clean hit within
  `RecentHitGraceSeconds`, and the **flat distance** is at most `Clash.RangeStuds` (6). Nothing checks which
  way the defender is facing or whether its swing would reach the attacker.
- The Active-window rule next to it uses `HitboxEngine.ActiveSwingReaches`, which tests the defender's real
  volume against the attacker and so is directional. The close-time rule is not.
- **Failure:** in a 2v1, a body winding up at a teammate is hit in the back within 6 studs. The rule turns
  that into a Trade: no damage, no stun, and both swings cancelled.

**Fix.** Gate the close-time rule on bearing. `bearing` is already computed at the top of `onHit` (the
attacker's bearing from the defender's facing). Require it to be inside the front arc: reuse
`DefenseConstants.BlockArcDegrees / 2`, or add `Clash.FacingDegrees` with a comment explaining why it differs.
Keep the existing four specs green and add one: "a rear hit on a defender a beat from opening is Clean".

### 1.4 A clash can empty a guard without breaking it, and the attacker-side charge skips the batch guard cache.

**VERIFIED** (uncommitted code).

- `applyContact` applies the clash's `-Clash.GuardDamage` (12) through `guard:Set`, which clamps at 0
  (`GuardMeter.lua:119-124`). The Trade path never calls `BreakGuard`. So a guard at 12 or less goes to 0
  with no break, and the next blocked hit breaks it.
- The `ClashChargesAttacker` branch writes the attacker's pool directly and does not update `batchGuard`. Any
  later contact in the same batch where that attacker is the defender is classified against the stale guard.

**DECISION: what should a clash do to a guard it empties?** Recommend: a clash never breaks a guard and
never takes it below 1. It is a neutral exchange, and the existing regen block (`spendsGuard`) already keeps
the pool low, so the next block still breaks it. The alternative is to treat reaching 0 as a `GuardBroken`.
Ask before you implement either. Fixing the `batchGuard` staleness is not a decision: do it in the same
change.

### 1.5 A clash looks different to each side, and the client cannot tell a clash from a mutual parry.

**VERIFIED.**

- `AttackConstants.ShakePresets` maps `Trade` to `HitLight` for the attacker and `HitHeavy` for the defender
  (`AttackConstants.lua:618`, `627`). For a lone clash (one contact), the two players get different shakes
  for a symmetric event.
- `DefenseOutcome.Clash` exists server-side, but `Clash` appears nowhere in `CombatFeedbackClient.lua` or
  `Shared/Damage/` feedback types. So the client cannot give a clash its own cue. (The uncommitted work adds
  `Clash` only to the Defense `StatePayload`, for the animation.)

**DECISION: carry `Clash` on the feedback payload** (`Shared/Damage/FeedbackBatch.lua`). It is an additive
optional field, but it is still a wire change. If yes, add a symmetric clash shake and hit-stop. If no, at
least make `ShakePresets.Trade` the same on both sides.

---

## 2. Camera (the "makes no sense" reports)

### Render order, verified

Every `BindToRenderStep` in client code, from a grep on 2026-10-26:

| Priority | Binding | Writes |
|---|---|---|
| Camera − 3 | `CameraFollow` | the `Follow` slot of `CameraOffsetComposer` (trail lag, root space) |
| Camera − 2 | `ShiftLockCamera` (offset step), `CameraShake` (undo) | the `ShiftLock` slot; removes last frame's shake |
| Camera − 1 | `LockOnController`, `CameraOffsetComposer` | `Camera.CFrame` look (spring); `Humanoid.CameraOffset` |
| Camera | default camera scripts | camera CFrame from the focus, zoom and occlusion |
| Camera + 1 | `ShiftLockCamera` (yaw), `FOVOffset`, `FlightCamera`, `BlimpCamera` | root yaw spring; FOV |
| Camera + 2 | `CameraShake` | adds rotation |
| Camera + 3 | `ParkourCamera` | adds roll (wall-run tilt) |

Two bindings at the same priority run in no guaranteed order. Nothing above depends on the order inside
Camera − 2 or Camera − 1 today. Keep it that way.

### 2.1 With lock-on and shift lock both on, the body faces parallel to the camera ray, not at the target. It sways off target after every swing.

**DERIVED. Confirm in Studio first.**

What is verified:
- `LockOnController.pullCamera` aims the camera along `aim - camera.Focus.Position` (`LockOnController.lua:174`).
- `ShiftLockCamera` springs the body's yaw to the camera's yaw (`ShiftLockCamera.lua:423-449`).
- The shoulder framing is `CameraConstants.ShiftLock.ShoulderOffset = Vector3.new(1.75, 0.5, 0)`, written into
  `Humanoid.CameraOffset` through the composer.
- `SwingTracking` turns the body toward the target at 540°/s during the windup, holds through Active, then
  `finish` hands the body back to shift lock (`SwingTracking.lua:140-141`).

What is derived: Roblox's default camera adds `Humanoid.CameraOffset`, in root space, to the subject
position it uses as the focus. That is `BaseCamera:GetSubjectPosition` in the stock `CameraModule`. If so,
the camera looks from a point 1.75 studs right of the body. The body, matching the camera's yaw, faces
parallel to that line, and its forward ray misses the target by about 1.75 studs. That is about
atan(1.75 / d): roughly 27° at `StepIn.StandoffStuds = 3.4`, and 16° at 6 studs. Each swing, tracking
corrects the facing. In recovery, shift lock turns the body back off target. Blocks and the next swing's
hitbox are judged from that off-target facing.

**Confirm:** in Studio, lock onto a dummy with shift lock on, stand still at 3-6 studs, and log the flat angle
between `root.CFrame.LookVector` and `target.Root.Position - root.Position`. If it is near 0, this item is
wrong: drop it and say so.

**Fix (if confirmed).** While a lock exists and shift lock is engaged, the body's yaw target is the flat
bearing from the root to the lock target, not the camera's yaw. The camera stays a soft spring on top. Keep
the existing spring and the `combatFacingOwned`/`parkourFacingOwned`/root-lock guards exactly as they are.
Only the target of the spring changes. Wiring: `LockOnController` lives in `Client/Combat` and requires UI
modules, and `ShiftLockCamera` lives in `Client/Camera`. Choose a direction that adds no require cycle and does
not pull Fusion or UI into a module a spec loads. A provider setter wired in `Main.client.lua` is one option;
`LockOnController` calling a `ShiftLockCamera` setter is another. Check `test.project.json` for whether
`Client/Camera` is mapped before relying on a spec there.

### 2.2 The lock-on pull stands down by measuring from the camera focus, not the body.

**VERIFIED.** `pullCamera` returns and zeroes its velocities when the flat distance from `camera.Focus.Position`
to the aim point is under `LockOnConstants.Camera.MinDistanceStuds = 2.5`. The focus carries the shoulder
offset and the `CameraFollow` trail, so the gate moves with the camera. At standoff range, with the target on
the shoulder side, the pull can cut out and restart from rest mid-exchange.

**Fix.** Measure that gate from the local root (`rootPart`), which `lockStep` already has. Keep aiming from
the focus for the look direction itself.

### 2.3 Unpredicted swings start their client presentation a round trip late.

**VERIFIED.**

- A predicted Basic/Heavy press starts locally at the press (`AttackInputClient.predictSwing`, line 666 on).
  Every other swing (hotbar arts, a press with the launcher modifier held, air-combo presses, a misprediction)
  starts when `Attack_Started` arrives: `startSwing(payload, now)` with `now = os.clock()` at arrival
  (`AttackInputClient.lua:929`).
- The server judged that swing to have started up to `AttackConstants.Latency.MaxLeadSeconds` (0.1) before
  the press arrived (CLAUDE.md, "Two swings that meet clash"). `AttackStartedPayload` carries no field saying
  how far in the swing already is (`AttackTypes.lua:110-145`).
- So for those swings, `SwingTracking` (`TurnEndsAt = now + windup`) keeps turning after the server's Active
  window has opened. Its own header says turning through Active "would sweep the server's hitbox sideways".
  The `SwingLunge` step and the clip are late by the same amount.

**DECISION: add `ElapsedSeconds` to `AttackStartedPayload`** (how far into the swing the server is when it
sends, plus nothing else). The client then starts with `startOffset` and backdates the listeners' clock.
Recommend yes. The alternative needs no wire change but is weaker: estimate from the press's own send time,
which the client knows per `PressId`. That is wrong whenever the server buffered the press. Either way, the
`OnAttackStarted` listeners need the swing's start time, not `os.clock()` at dispatch.

### 2.4 The swing step is integrated after physics and goes along the facing, not toward the target.

**VERIFIED (code). DERIVED (effect).**

- `SwingLunge` writes velocity on `Heartbeat` (`SwingLunge.lua:272`, `326`). `SwingTracking` moved to
  `PreSimulation` for exactly this reason: a Heartbeat write lands a frame late and fights the Humanoid for a
  step (its own comment above `onPreSimulation`).
- The step direction is the body's current `LookVector` (`SwingLunge.lua:319`), but its distance is resolved
  from the gap to the target. If the facing is off target (see 2.1), the step under-closes and drifts
  sideways.
- `HitStop.lua`'s header documents, from play, that a running Humanoid's walk controller re-accelerates inside
  the next physics step after a Heartbeat velocity write. If that holds here, how far a step carries depends
  on whether WASD is held.

**Confirm:** log the root's flat displacement over a Basic's step, with and without WASD held. **Fix:** move
the write to `PreSimulation`, and for a target-aware step (`not live.resolved` path), aim the horizontal
velocity along the flat bearing to the target, resolved on the step's first frame like the distance already
is. Keep `ParkourMotor.ApplyImpulse` as the seam, and keep the vertical axis carried, as the header requires.

### 2.5 Smaller camera notes. Do not prioritise these over the above.

- **VERIFIED.** `ParkourCamera` adds its roll at Camera + 3 with no undo. Roll does not change `LookVector`,
  so it does not accumulate the way the old shake did. Its one interaction is second-order: `CameraShake`'s
  undo at Camera − 2 multiplies by the inverse shake after the roll was composed on top. The error is
  amplitude times tilt. Note it; do not fix it in this pass.
- **VERIFIED.** A Heavy or Hotbar press plays the FOV press cue (`AttackInputClient.playPressCue`) even when
  the server will refuse or buffer it. Basic presses do not. This is acceptable as is.
- Lock-on has no way to switch targets except release and re-acquire. That is a missing feature, not a
  defect. **DECISION**: only if the user asks.

---

## 3. Latent conflict: a movement-locked move silently disables its own aim assist

**VERIFIED (code). Not live in shipped content.**

A move with `LocksWindup` or `LocksMovement` makes `HitboxEngine.setMovementLock` claim
`RootControl.Owners.Swing`, which publishes `RootControlLocked` (`HitboxEngine.lua:372-390`). On the client,
that one Attribute makes:

- `SwingTracking.rotationOwnedElsewhere` return true, so the windup is never tracked (`SwingTracking.lua:77`);
- `ParkourMotor.ApplyImpulse` refuse, so the swing step never happens (`ParkourMotor.lua:709`);
- `ShiftLockCamera` treat the facing as owned, so the yaw is frozen (`ShiftLockCamera.lua:367`).

No move in source sets either flag (`DefaultMoveRegistry.lua:238-239` sets both false, and
`Server/Combat/AuthoredMoves/` holds only READMEs), but the Move Editor can set them on DataStore records.
**DECISION: should a swing's own movement lock stop its own facing correction?** Recommend no. The lock is
about translation (`SwingRooted` already pins WalkSpeed through RunSystem), and tracking is the swing's aim.
Do not change this without an answer. Report it either way.

---

## 4. Housekeeping on the in-flight diff

1. **VERIFIED.** `stylua --check` fails on the LF copies of `DefenseConstants.lua` (the line
   `DefenseConstants.ParryAnimationId ="rbxassetid://..."`, line 432) and `DefenseSystem.lua`. Format only the
   files you touch, and follow CLAUDE.md's CRLF note.
2. **VERIFIED, and its intent is unknown.** `AttackAnimations` `Basic:3` is now `121830343644533`, the same clip
   as `Basic:1` (`AttackAnimations.lua:152`). `Air:3` borrows `Basic:3`'s clip (`BORROWED_FROM`, line 135). A
   stage's hitbox timing is read off the clip's `AttackM<stage>` marker first, then `Hit`
   (`AttackWindows.resolveMarker`, line 285). If the `Basic:1` clip carries only `AttackM1`, stage 3 falls back to
   `Hit` or the authored windup. **Ask the user whether this was deliberate**, and check the boot log's marker
   line for `Basic:3`.
3. **VERIFIED.** `DefenseClient.lua:588`'s comment "Sent only on a parry: the snap…" now sits above the new
   clash block instead of the `FaceTowards` block it describes. Move it.
4. **VERIFIED. Doc rot to fix only in files you already touch:**
   - `AttackInputClient.lua`'s header, the `playSwing` comment and `AttackTypes.AttackStartedPayload.
     AnimationId` all say every Default move has a blank `AnimationId`. `AttackAnimations` authors real ids.
   - `SwingLunge.lua`'s header says it fires on "the confirmation rather than the press". Since prediction, a
     predicted swing fires it at the press.
   - `ShiftLockCamera.lua`'s header cites the deleted `CombatSystem.lua`. `check-stale-refs.py` exists for this
     class of problem; read it before editing.

---

## 5. What was checked and is fine. Do not re-open these.

- `CameraShake` no longer accumulates. The undo step removes last frame's rotation before the camera scripts
  read the look direction.
- `LockOnController` deliberately runs before the camera scripts, so occlusion and player input apply on top of
  its pull.
- `CameraFollow`'s trail goes through `CameraOffset`, so occlusion places the camera after the trail. It cannot
  push the camera into a wall.
- Parry rewind, stun parry, rally, guard-break-as-one-opening, evade rewind and the feint refund were traced and
  fixed in the 2026-10-25 Deepwoken pass. Leave them unless a spec you add proves otherwise.
- Block resolution (arc, backstab hemisphere, drain by PowerLevel, held key behind a spent parry window) showed
  no defect in this review. If you find one, prove it with `CombatTrace` output (search "CombatTrace" in the Live
  Console) before you change anything.

---

## 6. Order of work

1. Measure the baseline. Strip the `ParkourConstants` BOM, build `test.project.json`, and run the suite on the
   current tree, with Studio closed and the user's OK. Record pass and fail counts, and the failing names.
2. §1.1, §1.2 and §1.3 (defects with no decision needed), one concern each, each with its spec.
3. Ask the user the DECISIONs in §1.4, §1.5, §2.3, §3 and §4.2 together, in one message, each with your
   recommendation.
4. §2.2 (no decision).
5. Studio confirmation for §2.1 and §2.4. Then implement whichever is confirmed.
6. The DECISION items the user approved.
7. §4 housekeeping.
8. Full validation (§7).

## 7. Validation

- `selene src/`: 0 errors. The two pre-existing `UDim2.fromScale` warnings may remain.
- `stylua --check` on every file you touched (LF copies; see CLAUDE.md).
- `python scripts/check-single-writers.py`, and `python scripts/check-live-project.py` if a project file changed.
- The full suite: the same pass/fail set as your baseline, plus your new specs passing. No new failure. If a
  baseline failure changes, explain why. `WeaponInventory.spec` is known to fail intermittently on pacing:
  re-run before you investigate it.
- Before claiming anything is wired, check inbound requires (CLAUDE.md, "Before claiming something is wired").
- **A playtest checklist for the user**, because nothing here can be felt headlessly. Run it in Studio with
  Network → Incoming Replication Lag at 0.1 s:
  1. Lock on with shift lock, M1 string on a dummy: the body stays on target through recovery (§2.1).
  2. Parry an M1, then immediately M1 with no target in front: the body still turns with the camera afterwards
     (§1.2).
  3. Parry from the side: the parrier turns toward the attacker, at most 80° (§1.1).
  4. Two players swing at the same time face to face: they clash. Swing into the back of someone winding up at a
     dummy: a clean hit (§1.3).
  5. Cast a hotbar art at a target: the turn stops when the hit lands, and does not keep sweeping (§2.3, if
     approved).

## 8. Report back with

What changed, per concern, with file:line references. What you confirmed or refuted in Studio, with the numbers.
The baseline and final suite counts. The decisions you are still waiting on. Anything in this document that
turned out to be wrong.
