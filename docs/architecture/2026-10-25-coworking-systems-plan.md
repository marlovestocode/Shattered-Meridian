# Coworking systems: finish the arbiters, stop the rebuilds (2026-10-25)

Scope: all of `src/` (772 Lua files) and `scripts/`. This is a plan, not a pass. Nothing was changed. The agent prompt
that executes it is [`2026-10-25-coworking-systems-agent-prompt.md`](2026-10-25-coworking-systems-agent-prompt.md).

It builds on `2026-10-25-cohesion-audit.md` and `2026-10-25-codebase-audit.md` and does not restate their open
items unless the item belongs to a workstream here (then it is cited, not re-argued).

W0 re-measure (2026-10-25, branch `cohesion/coworking-systems`): render priorities (8 modules in 3 slots), listener-list lines,
animator bypasses (3), `LocalAnimator` missing, inbound-require counts and duplicate-body count all reproduced. Moved: Blimp/Boat
shared lines, bare frame callbacks (18 -> 28), the RunSystem restraint row. Corrected in place below.

**Evidence level.** Every count and line reference below was measured from source on 2026-10-25 by grep, a
require-graph count, or a function-body hash (the script is in the agent prompt's appendix and becomes
`scripts/check-duplicate-bodies.py` in W6). Nothing was run
in Studio or played. "Inferred" marks a conclusion reached by reading.

## 1. Diagnosis

### 1.1 The small patterns are consolidated. The arbiters are not.

The CLAUDE.md shared-module table works. Its modules are widely adopted, and only a few hand-rolled copies remain:

| Shared module | Inbound requires (non-spec) | Residual hand-rolled sites |
|---|---|---|
| `CharacterUtil` | 61 | 2 `FindFirstChild("HumanoidRootPart")` in pose FX (GuardStrainPose:182, HitFlinchPose:205), 2 in bot/dummy adornee lookups; the 5th grep hit is CharacterUtil itself |
| `PlayerLifecycle` | 55 | 4 raw `CharacterAdded` (Blimp/Boat controllers, FurnacePrompt, EnvironmentProbe); IntroClient and SpectateController also touch it, for other reasons |
| `Trove` | 53 | — |
| `Inset` / `Stack` | 49 / 42 | 4 bare `UIPadding` (KeyCap, NumericField, two DevTools) |
| `RateLimiter` | 29 | none: every public remote has one |
| `CallbackList` | 11 | **6 hand-rolled `OnChanged` lists** (§2, W1) |

Only 11 function bodies are byte-identical across files (re-measured W0: `TOTAL 11`; 5 of them are the `OnChanged` bodies W1 removes). So copy-paste is **not** the problem.

The problem is one level up. Several questions that more than one system has to answer have **no single owner**,
or have an owner that was half-built and then abandoned:

| Question | Today | Evidence |
|---|---|---|
| **Which animation owns this body?** | `Shared/Animation/AnimationManager.lua` says "nothing else in the codebase touches an AnimationTrack directly", and that it *replaced* CombatAnimator/FlightAnimator/EmoteAnimator. **All three still exist.** They still `LoadAnimation` on their own and run their own Heartbeat with `DOMINANT_WEIGHT` peepholes. The header cites `Client/FX/LocalAnimator.lua`, **which does not exist.** | `CombatAnimator.lua:270,386,520`, `EmoteAnimator.lua:151,214`, `FlightAnimator.lua:105,189`; AnimationManager is used only by Parkour, AttackInput, Defense, HitStop, Grab and the bot |
| **May this body act (attack / evade / block / sprint / vault / emote / rotate)?** | Each consumer reads its own hand-picked subset of ~12 Humanoid Attributes. The subsets differ. | §1.2 |
| **What order do per-frame client systems run in?** | 37 independent frame callbacks (re-measured W0: 21 `BindToRenderStep` bindings plus 28 bare `Heartbeat`/`RenderStepped`/`PreRender` `:Connect` callbacks in 24 client files). **4 modules bind at `RenderPriority.Camera + 1`** (BlimpCamera, FlightCamera, ShiftLockCamera, FOVOffset), 2 at `Camera - 2` and 2 at `Camera - 1`. Roblox does not define the order within one priority. | §1.3 |
| **Who writes the camera's CFrame?** | 6 writers (Blimp, Flight, LockOn, CameraShake, Intro, Placement). Mutual exclusion is done with flags each one reads from the others. FieldOfView and CameraOffset each already have a composer (`FOVOffset`, `CameraOffsetComposer`) that was built to end exactly this pattern. CFrame has none. | `grep "Camera.CFrame ="` |
| **Who writes a joint's `Transform`?** | `TransformLayer` composes the *additive* layers (GuardStrain, HitFlinch). `GrabHoldPose`, `VesselArmPose` and `VesselPilotPose` write *absolute* Transforms around it. `VesselPilotPose.lua:156` writes `RootJoint.Transform`, which is the joint HitFlinchPose composes onto (inferred conflict on a pilot who gets hit). | `grep ".Transform ="` |
| **What order do server per-frame systems run in?** | `CombatTick` owns combat. `GameplayEvents.HeartbeatTick` (13 subscribers) is a second ticker. `RunSystem` and `ParkourSystem` connect their own Heartbeat. Order between the three is connection order, and the CombatTick header itself has to explain it. | `CombatTick.lua:20-25`, `RunSystem.lua:698`, `ParkourSystem.lua:477` |
| **How does a module announce a change?** | Three mechanisms: `GameplayEvents` (deferred BindableEvent), `CallbackList` (synchronous), and 6 hand-rolled listener arrays. No document says which one to use when. | `grep "changedListeners"` |
| **Where does vehicle-mount bookkeeping live?** | CLAUDE.md says the vehicles "differ in exactly two files each". BlimpSystem and BoatSystem share **370 identical code lines**, and the two controllers share **204** (W0 re-measure with the same difflib method; was 374 / 208). `Server/Vessel` holds only `VesselAssembly` and `VesselMount`. | difflib over comment-stripped code |

### 1.2 The restraint matrix nobody owns

Read from source. Each row is a consumer; each column is an Attribute it consults.

| Consumer | Frozen | Grabbed | Grabbing | Mounted | Flying | RootLocked | SwingRooted | Hitstun | Busy | EmoteLock | AirHeld | Domain |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `AttackRequestSystem.bodyGate` (server) | ✓ | via Grab | via Grab | ✓ | | | | via Damage | via Defense | | via AirCombo | |
| `DefenseSystem.evadeBodyRefusal` (server) | ✓ | ✓ | ✓ | ✓ | | | | ✓ | ✓ | | ✓ | NoEvade |
| `RunSystem` live sample (server) | ✓ | ✓ (+`GrabThrowing`) | | ✓ | ✓ | | ✓ | ✓ (`live.HitstunUntil`, `RunSystem.lua:398`) | ✓ | ✓ | | Rooted + speed scale |
| `AttackInputClient` local gate | | ✓ | ✓ | ✓ | | | | | | | | |
| `ParkourController` restraint (client) | ✓ | | | | ✓ | ✓ | | | | ✓ | | |
| `ShiftLockCamera` (client) | | ✓ | | ✓ | ✓ | ✓ | | | | | | |
| `EmoteSystem` (server) | | | | ✓ | | | | | | | | |

W0 re-check (read from source): the attack, evade, AttackInputClient, ParkourController, ShiftLockCamera and EmoteSystem rows
match (`AttackRequestSystem.lua:801,809`, `DefenseSystem.lua:736-743`, `AttackInputClient.lua:645-647`, `ParkourController.lua:234-237`,
`ShiftLockCamera.lua:474-511`, `EmoteSystem.lua:268`). The RunSystem row was wrong in three cells (Hitstun, `GrabThrowing`, Domain), now fixed above
(`RunSystem.lua:296-304,344-365`). Order differs by consumer: `bodyGate` checks Mounted then Frozen; `evadeBodyRefusal` checks
Committed, then Grabbed/Grabbing/Mounted ("Restrained"), then Frozen.

Some of these gaps are deliberate. For example, the server is the authority for Frozen, so the client attack gate
does not need it. Others look accidental. For example, the parkour client does not consult Mounted or Grabbed
directly and relies on RootControlLocked covering both (inferred). **Nobody can tell which is which without reading
seven files.** Every new restraint (Frozen landed this week) has to be threaded through each consumer by hand, and
the 2026-10-25 audit's finding 11 ("Frozen doesn't stop combat") is exactly that thread being missed.

### 1.3 Client frame order

```
Character+1   BlimpController, BoatController (pose)
Camera-3      CameraFollow
Camera-2      ShiftLockCamera.offset, CameraShake.undo          <- 2 at one slot
Camera-1      LockOnController, CameraOffsetComposer            <- 2 at one slot
Camera+1      BlimpCamera, FlightCamera, ShiftLockCamera, FOVOffset  <- 4 at one slot
Camera+2      CameraShake
Camera+3      ParkourCamera
First         TransformLayer;  RENDER_PRIORITY (local) x3 pose FX; INPUT_HOLD_PRIORITY HitStop
+ 28 Heartbeat/RenderStepped:Connect callbacks (24 client files, W0 count; was 18) with no stated order
```

### 1.4 Why things get recreated

From git history (168 commits, 83 deleted `src` files) and the memory log, the project's large features have
repeatedly been **rebuilt instead of migrated**: combat (`cc05003`), the Move Editor (deleted and rebuilt
2026-09-29), the admin panel, the character menu, the hotbar dock, the furnace gauge, and four animators (per
AnimationManager's own header). The recurring shape:

1. A new canonical module is written next to the old ones, with a header saying it replaces them.
2. The two or three easiest consumers move to it.
3. The session ends. The hard consumers stay on the old path. The header is now false.
4. The next session finds two systems for one job, trusts neither, and writes a third.

AnimationManager (3 of 6 animators never moved, a cited file that does not exist), CallbackList (6 copies left), the
Vessel layer (≈580 shared lines left), and `CombatSystem` (162 stale comment references) are all stuck at step 3.
The fix is **finishing**, plus a rule and a gate that make step 3 an unfinished change rather than a stopping point.

## 2. Workstreams

Ordered by leverage ÷ risk. Each one ends with every consumer moved, the old path deleted, headers true, and a gate
that stops it regressing. A workstream that cannot reach that end stops and escalates. It must not leave a fourth
half-migration behind.

### W0. Baseline and the ownership map (no behaviour change)

1. Run the full gate list and the suite. Record pass/fail. The last known baseline is **3538 / 7**: feint ×2 and
   TrainingBot ×5, all pre-existing. Re-measure it; do not trust this number.
2. Re-run every count in §1 against the current tree (the branch moves). Correct this doc wherever a count changed.
3. Add a **"Who owns what"** section to `docs/software-architecture.md`. It is a table of *question → owning module →
   how a consumer asks*, covering the rows in §1.1 plus remotes, profile writes, kill credit and the frame phases.
   CLAUDE.md's table maps *pattern → module*. This one maps *question → owner*, and it is the first thing a future
   agent reads before creating a module. Mark rows that this plan has not finished yet as `(migrating: Wn)`.

### W1. Finish CallbackList (mechanical; low risk)

Move the six hand-rolled lists onto `CallbackList`: `DefaultMoveRegistry.lua:115`, `MoveRegistryManager.lua:58`,
`HotbarBindings.lua:65`, `InputDevice.lua:153`, `KeybindManager.lua:71`, and `ParkourSystem.lua:109`
(`actionStartedCallbacks`). Keep each public `OnX(fn) -> disconnect` signature identical. Add a `:Clear()` call
wherever a spec resets one. `Logger.entryListeners`, `GameplayEvents.heartbeatHandlers` and
`CombatAnimator.perLifeResetHandlers` are keyed differently: inspect each, and either convert it or note in its
header why it stays. Afterwards, update the CallbackList row in CLAUDE.md, which currently lists the remaining copies.

### W2. Finish the Vessel layer (medium; server + client)

1. Server: create `Server/Vessel/VesselMountRegistry.lua` (`New(config)`, same shape as its siblings). It owns
   `sweepStaleMounts`, `onHullTouched`, `clearInheritedInstances`, `cancelPendingWorldEntry`,
   `broadcastMountChanged`, `sendExistingMounts` and `mount`, with the 2-7-line differences passed in as config
   or callbacks. BlimpSystem and BoatSystem bind it. Also: `BlimpDrive.ClampLead`/`BoatDrive.ClampLead`.
2. Client: move `matchesControl`, `refreshPoseBinding` and the raw `CharacterAdded` rebind (via `PlayerLifecycle`)
   from Blimp/BoatController into a shared `Client/Vessel/` helper. **A new top-level `Client/Vessel` folder needs a
   `test.project.json` entry.**
3. Done when the comment-stripped shared-line count between each pair is near zero, apart from the drive
   integrator and the mode machine, which really are vehicle-specific. CLAUDE.md's "exactly two files" claim is then
   true again.

### W3. One body-restraint vocabulary (high leverage; design-sensitive)

Goal: "may this body do *verb* right now" for **Attribute-only** restraints has one answer per verb, in one place.

1. **Tabulate first, code second.** Extend §1.2 into the full verb × restraint matrix for every consumer, with a
   `file:line` per cell. Mark each blank cell as *deliberate* (cite the comment or reason) or *unexplained*.
2. Create `Shared/Combat/BodyRestraint.lua`: a pure module that reads Attributes and never requires a System (the
   same rule `DomainRules` and `ParkourOwnership` follow). It exposes `Of(humanoid, now) -> RestraintSet` and
   `Refusal(humanoid, verb, now) -> string?`. The verb → refused-restraints policy is one table in one Constants
   module. Fold `FrozenBody`, and possibly `Invulnerability`, into it, or have them delegate to it.
3. Migrate consumers so that **every current answer is preserved bit-for-bit**, including the gaps that look wrong.
   Each *unexplained* gap becomes an escalation: a binary choice with the consequence of each option. Do not change
   it silently.
4. **Leave alone:** the record-backed server gates (`DefenseSystem.CanAttack`, `DamageSystem.CanAttack`,
   `GrabSystem.CanAttack`, `AirComboSystem.CanAttack`). They own state with timestamps and are the documented seams.
   `BodyRestraint` sits beside them for the attribute-only part; it does not replace them. `bodyGate`'s order of
   refusals must not change, because the refusal reason reaches the client and `TransientRefusals`.
5. Gate: a spec that pins the policy table, and an extension to `check-single-writers.py`, or a new check, that
   fails on a new `GetAttribute(AttributeConstants.<restraint>)` outside `BodyRestraint` and its listed exemptions.

### W4. Client frame order and camera arbitration (medium; REQUIRES PLAYTEST)

1. Create `Client/FrameOrder.lua` (or a constants table in `Client/Camera`): one ordered, named list of every
   RenderStep slot, as `{ Name, Priority }`. Every `BindToRenderStep` reads its slot from that list. **Two modules
   never share a priority value.** Where four share `Camera + 1` today, read each module to work out the order
   that is actually *required* (who reads whose write), and assign distinct values. Record the reasoning in the
   list, the same way `CombatTick.PHASES` does.
2. Do the same for the 28 bare `Heartbeat`/`RenderStepped:Connect` callbacks only where one reads state another
   writes in the same frame. Leave independent ones where they are.
3. Camera CFrame: write the arbitration down before writing code. The three follow-style writers (Blimp, Flight,
   ShiftLock) are mutually exclusive modes. Shake is additive. LockOn pre-aims. Intro and Placement are Scriptable
   takeovers. If a mode arbiter (`CameraMode.Claim(owner)`, the same shape as `RootControl`) replaces the flag
   peepholes with no behaviour change, build it. If it does not, stop at the priority table and escalate.
4. Gate: `scripts/check-render-order.py` fails on a `BindToRenderStep` whose priority does not come from the list,
   and on two entries with one value.

### W5. Finish AnimationManager (highest risk; REQUIRES PLAYTEST; do last)

1. **Spike, no commit:** read AnimationManager's layer/claim model and its six consumers. Then decide, and write the
   decision down: either (a) locomotion, armed idle, emotes and flight become claims on named layers, or (b) one of
   them has a real reason to stay outside (for example, CombatAnimator's beat-the-default-Animate-script weight
   trick needs something AnimationManager lacks).
2. If (a): create the `LocalAnimator` the header promises, as the local rig's single AnimationManager instance plus
   its layer names. Migrate Emote, then Flight, then CombatAnimator locomotion and armed idle, one commit each.
   Delete `AnimationTrackUtil`'s evaluator once nothing uses it. Remove every cross-module peephole (the `Flying`
   read in CombatAnimator, `SetLocomotionSuppressed`). `HitStop` freezes through the manager.
3. If (b) for any of them: correct AnimationManager's header so it states the exception and its reason. A header
   that is true and narrower beats a header that is broad and false.
4. Read `docs/animation-systems.md`, and the memories on Core priority, `toolnone`, and server one-shots, before
   touching priorities.
5. Playtest checklist: walk, run, armed run, armed idle with a drawn weapon, each emote (loop and one-shot), take
   off / cruise / boost / land, hit-stop during each, die during each, respawn.

### W6. Guardrails against the next rebuild (process; do alongside W0, finish last)

1. **CLAUDE.md, new short section "Extend, migrate, never fork".** Before creating a module, check the ownership map
   (W0) and CLAUDE.md's table. A new module that *replaces* an existing one is one change: every consumer moves and
   the old module is deleted in the same branch, or the new one is not started. A from-scratch rebuild of an existing
   feature needs the user's explicit go-ahead and a written migration list.
2. `scripts/check-duplicate-bodies.py`: the function-body hash used for §1.1, run as a ratchet. Its current count is
   the ceiling, and it may only go down. Ignore bodies under 6 statements.
3. `scripts/check-orphans.py`: the A5 orphan scan from the cohesion audit, which is still not a script. It fails on a
   module with no non-spec inbound require, except for a listed allowlist (`Main` entry points, `AuthoredMoves/`).
4. `scripts/check-header-claims.py` (optional, only if cheap): fails when a header cites a `Client/...`/`Server/...`/
   `Shared/...` `.lua` path that does not exist. That is how `LocalAnimator` went unnoticed.
5. In `software-architecture.md`, state which event mechanism to use when: `GameplayEvents` for deferred,
   cross-System, server-wide facts; `CallbackList` for a module's synchronous extension point; a Humanoid Attribute
   for state that crosses the client/server boundary or a layer that may not require the other.

### Deliberately out of scope

- Every design escalation still open from the 2026-10-25 audits: faction assignment, `CombatPowerConstants.Enabled`,
  the held-hit body gate, blockcounter, feint lockout, server boot isolation. These are decisions for the user, not
  cohesion work.
- The progression stubs (Absorb, Awakening, Achievement, Territory, World, Faction). Those are features.
- The frozen combat feel skeleton (timings, windows, rewind caps). No workstream here may change a number.
- Splitting big files (A5), except `AttackRequestSystem`'s `PressBuffer`, and only if W3 is already editing that
  region.
- Renames such as `Roll` → `Evade` in FX. A rename gets its own commit, never mixed into a migration.

## 3. Order and dependencies

```
W0 ─┬─ W1 ─┐
    ├─ W2 ─┼─ W6 (finish)
    ├─ W3 ─┤
    └─ W4 ─┴─ W5
```

W1-W4 touch disjoint files, apart from CLAUDE.md and `software-architecture.md`, which W0 and W6 own; append to those
rather than rewriting them. W5 goes last because it shares `HitStop`, the pose FX and the frame order with W4.

## 4. Done means

| Measure | Now | Target |
|---|---|---|
| Hand-rolled listener lists | 6 (+3 to judge) | 0, or each one justified in its header |
| Blimp/Boat shared code lines | 370 server / 204 client | under 40 each |
| Modules at a shared RenderStep priority | 8 (in 3 slots) | 0 |
| Consumers reading restraint Attributes directly | 7+ | `BodyRestraint` plus listed exemptions |
| Animators that bypass AnimationManager | 3 | 0, or each one documented as an exception |
| Headers citing a module that does not exist | at least 1 (`LocalAnimator`) | 0, gated |
| Suite | 3538 / 7 (re-measured W0: 3538 / 7, same) | no new failures; the 7 unchanged unless fixed on purpose |
| Gates | 7 scripts | +3 to 4 ratchets (duplicates, orphans, render order, header claims) |
