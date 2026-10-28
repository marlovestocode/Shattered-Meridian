# Coworking systems: one mechanism per job, across the whole game (2026-10-25)

Scope: all of `src/` (772 Lua files, 204 specs) and `scripts/`. The agent prompt that executes this plan is
[`2026-10-25-coworking-systems-agent-prompt.md`](2026-10-25-coworking-systems-agent-prompt.md). Each session takes **one spine**
(§3), and a kickoff prompt per spine is at the end of that file.

Builds on `2026-10-25-cohesion-audit.md` and `2026-10-25-codebase-audit.md`. It does not restate their open items, except where an
item belongs to a workstream here; those are cited, not re-argued.

**Revision 2 (2026-10-25).** Revision 1 covered only the arbiters: who owns the body, the camera, the frame and the animation.
A second, wider dive found that most of the game's systems also **hand-assemble the same four or five mechanics** each time they
are built: decoding untrusted data, declaring a remote, pushing a player's state to their client, routing input, registering
content, scoping per-player tables and building a test rig. Revision 2 adds a shared foundation for each of those. That is
where most of the "every feature is rebuilt from scratch" cost actually lives.

W0 re-measure (2026-10-25, branch `cohesion/coworking-systems`): render priorities (8 modules in 3 slots), listener-list lines,
animator bypasses (3), `LocalAnimator` missing, inbound-require counts and the duplicate-body count all reproduced. Moved since
revision 1: Blimp/Boat shared lines, bare frame callbacks (18 -> 28) and the RunSystem restraint row. Corrected in place below.

**Evidence level.** Every count and line reference was measured from source on 2026-10-25, by grep, a require-graph count, a
function-body hash (the agent prompt's appendix) or difflib. Nothing was run in Studio or played. "Inferred" marks a conclusion
reached by reading.

---

## 1. Diagnosis

### 1.1 The small helpers are shared. Everything above them is assembled by hand.

The CLAUDE.md shared-module table works at the level it was written for:

| Shared module | Inbound requires (non-spec) | Residual hand-rolled sites |
|---|---|---|
| `CharacterUtil` | 61 | 2 `FindFirstChild("HumanoidRootPart")` in pose FX (GuardStrainPose:182, HitFlinchPose:205), 2 in bot/dummy adornee lookups |
| `PlayerLifecycle` | 55 | 4 raw `CharacterAdded` (Blimp/Boat controllers, FurnacePrompt, EnvironmentProbe) |
| `Trove` | 53 | — |
| `Inset` / `Stack` | 49 / 42 | 4 bare `UIPadding` (KeyCap, NumericField, two DevTools) |
| `RateLimiter` | 29 | none: every public remote has one |
| `CallbackList` | 11 -> **18 (W1 done)** | 0 unjustified |

Only 10 function bodies are byte-identical across files (W1 removed one group). Copy-paste is not the problem.

**The problem is that each shared helper is a part, not an assembly.** Anyone building a remote, a profile field, a replicated
value, an input or a test reaches for the right parts and then wires them together by hand, slightly differently each time.
§1.2 to §1.10 measure each such assembly.

### 1.2 Arbiters that are missing or half-built (revision 1, re-measured in W0)

| Question | Today | Evidence |
|---|---|---|
| **Which animation owns this body?** | `AnimationManager`'s header says "nothing else touches an AnimationTrack directly" and that it *replaced* CombatAnimator/FlightAnimator/EmoteAnimator. **All three still exist**, with their own `LoadAnimation`, their own Heartbeat and `DOMINANT_WEIGHT` peepholes. The header also cites `Client/FX/LocalAnimator.lua`, **which does not exist**. | `CombatAnimator.lua:270,386,520`, `EmoteAnimator.lua:151,214`, `FlightAnimator.lua:105,189` |
| **May this body act?** | Each of at least 7 consumers reads its own subset of about 12 Humanoid Attributes, and the subsets differ. | §1.3 |
| **What order do client frame systems run in?** | 21 `BindToRenderStep` bindings plus 28 bare `:Connect` callbacks. **4 modules share `Camera + 1`**, and 2 more pairs share a slot. | §1.4 |
| **Who writes the camera's CFrame?** | 6 writers that exclude each other through flags. FOV and CameraOffset each have a composer; CFrame has none. | `grep "Camera.CFrame ="` |
| **Who writes a joint's `Transform`?** | `TransformLayer` composes the additive layers. GrabHoldPose, VesselArmPose and VesselPilotPose write absolute values around it. `VesselPilotPose.lua:156` writes `RootJoint`, the joint HitFlinch composes onto (inferred conflict). | `grep ".Transform ="` |
| **What order do server frame systems run in?** | Three tickers: `CombatTick`, `GameplayEvents.HeartbeatTick` (13 subscribers), and RunSystem/ParkourSystem each with their own Heartbeat. Their relative order is connection order. | `CombatTick.lua:20-25`, `RunSystem.lua:698`, `ParkourSystem.lua:477` |
| **Where does vehicle-mount bookkeeping live?** | CLAUDE.md says the vehicles "differ in exactly two files". In fact BlimpSystem and BoatSystem share **370 identical code lines**, and the two controllers share **204**. | difflib |

### 1.3 The restraint matrix nobody owns

| Consumer | Frozen | Grabbed | Grabbing | Mounted | Flying | RootLocked | SwingRooted | Hitstun | Busy | EmoteLock | AirHeld | Domain |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `AttackRequestSystem.bodyGate` (server) | ✓ | via Grab | via Grab | ✓ | | | | via Damage | via Defense | | via AirCombo | |
| `DefenseSystem.evadeBodyRefusal` (server) | ✓ | ✓ | ✓ | ✓ | | | | ✓ | ✓ | | ✓ | NoEvade |
| `RunSystem` live sample (server) | ✓ | ✓ (+`GrabThrowing`) | | ✓ | ✓ | | ✓ | ✓ (`RunSystem.lua:398`) | ✓ | ✓ | | Rooted + speed scale |
| `AttackInputClient` local gate | | ✓ | ✓ | ✓ | | | | | | | | |
| `ParkourController` restraint (client) | ✓ | | | | ✓ | ✓ | | | | ✓ | | |
| `ShiftLockCamera` (client) | | ✓ | | ✓ | ✓ | ✓ | | | | | | |
| `EmoteSystem` (server) | | | | ✓ | | | | | | | | |

Source lines: `AttackRequestSystem.lua:801,809`, `DefenseSystem.lua:736-743`, `AttackInputClient.lua:645-647`,
`ParkourController.lua:234-237`, `ShiftLockCamera.lua:474-511`, `EmoteSystem.lua:268`, `RunSystem.lua:296-304,344-365`. The consumers
also check in different orders: `bodyGate` checks Mounted before Frozen, while `evadeBodyRefusal` checks Committed, then
Restrained, then Frozen.

### 1.4 Client frame order

```
Character+1   BlimpController, BoatController (pose)
Camera-3      CameraFollow
Camera-2      ShiftLockCamera.offset, CameraShake.undo               <- 2 at one slot
Camera-1      LockOnController, CameraOffsetComposer                 <- 2 at one slot
Camera+1      BlimpCamera, FlightCamera, ShiftLockCamera, FOVOffset  <- 4 at one slot
Camera+2      CameraShake
Camera+3      ParkourCamera
First         TransformLayer; RENDER_PRIORITY (local) x3 pose FX; INPUT_HOLD_PRIORITY HitStop
+ 28 bare Heartbeat/RenderStepped/PreRender callbacks in 24 client files, with no stated order
```

### 1.5 Untrusted data is decoded by hand, everywhere (NEW)

Every boundary where data arrives untrusted decodes it with inline `typeof` checks: remote arguments, DataStore records,
settings and authored content.

| Measure | Count |
|---|---|
| `typeof(x) ==/~= "..."` checks in server code | **~290** (PlayerDataSystem 79, MoveEditorSystem 32, DevMenuSystem 23, SettingsSystem 18, MoveRecordCodec 14, MoveRegistryManager 13, BugReportSystem 12, BloodlineManager 12, KitEditorSystem 10, AttackRequestSystem 10, ...) |
| Hand-written NaN checks (`x ~= x`) | **68** |
| Modules using `Shared/Sanitize.lua`, which exists *because* five modules each rediscovered the NaN trap | **6** |
| `PlayerDataSystem.DecodeProfile` plus the migration chain, hand-decoding every domain's slice | lines **717-1093** |
| Domains that own their own codec | **1** (`InventoryModel.Decode`, `PlayerDataSystem.lua:~857`) |

Adding a profile field means editing `Types`, `CreateDefaultProfile`, `CopyProfile`, `EncodeProfile`, `DecodeProfile` and
`Migrations`, all inside one 1878-line file that its own domain does not own. Inventory is the one domain that does it the
cohesive way: it owns its own decoder.

### 1.6 Every remote is assembled from four parts by hand (NEW)

There are 132 `NetworkBridge.Create*` calls and **73 server handlers** (30 `OnServerEvent`, 43 `OnServerInvoke`). Each one
hand-assembles the same parts: get the remote, check a `RateLimiter` (51 sites), check `typeof`/NaN per argument, wrap it in
`RemoteHandler` (33 sites) or `AdminGate` (16 sites), and log the refusal. `BootManifest`'s `Remotes` list is a **second,
hand-maintained copy** of which remotes each System creates. The result shape is mostly consistent: 224 `Success = ...` sites.

### 1.7 A player's own state reaches their client through about 10 private channels (NEW)

`CharacterSheetSystem`'s header describes the pattern and calls it the norm: *"Every other progression System that a UI needs
already solved this the same way, by owning its own narrow remote."* Each channel has its own push on profile load, its own pull
for a late-opening UI ("nothing caches an unheard RemoteEvent"), its own payload type and its own client mirror:

| Slice | Server push | Client mirror |
|---|---|---|
| Qi, Meridian XP, Tier | `QiSystem:150`, `MeridianSystem:52`, `TierSystem:175` (+ Player Attribute `:164`) | `UI/State/ClientState` |
| Emote unlocks + loadout | `EmoteSystem:176,186` | `ClientState` |
| Bounty "marked" | `BountySystem:218` | `ClientState` |
| Engagement | `EngagementSystem:295` | `ClientState` |
| Character sheet (push + `GetSheet` pull) | `CharacterSheetSystem:147` | `CharacterMenuClient` (private) |
| Art state (push + catalogue pull) | `ArtSystem:231` | `CharacterMenuClient` (private) |
| Inventory snapshot | `InventorySystem:164` | `InventoryClient` (private) |
| Weapon selection | `WeaponInventorySystem:169` | `WeaponInventoryClient` (private) |
| Bounty board (push + pull) | `BountySystem:202` | **`BountyTab` screen, subscribing to a remote directly**, which ClientState's header forbids |

`ChangeNotifier`, the module built for "push only when the value changed", has **one** consumer file outside its own. `ClientState`'s
header is also stale: it says "ArtSystem ... remain empty `Init()`s", which is false.

### 1.8 Input has a router, and most input bypasses it (NEW)

`InputRouter`'s header: *"the ONE UserInputService.InputBegan/InputEnded connection for action dispatch."* Only **5 modules** bind
through it (AttackInput, LockOn, Defense, ParkourInput, Settings). **About 20 still connect raw `UserInputService` events**: Blimp,
Boat, GrabInput, RunController, ShiftLockCamera, CharacterMenu, Inventory, BugReport, EmoteWheel, Onboarding, FpsCounter,
ParkourDebug and the DevTools. Each of those re-solves `gameProcessed`, the modal block and gamepad chords, or doesn't.

- **`FlightController.lua:247-263` hard-codes W/A/S/D/Space/LeftControl with `IsKeyDown` and has no gamepad path at all.** Flight
  ignores rebinds and, inferred from source, cannot be flown on a controller. That is a real player-facing gap; see the escalation
  in W12.
- Debug keys are declared in three places: `DebugConstants` (F3, F7), `KeybindConstants` (F5, F8) and `ParkourConstants` (F6). No
  check catches a clash.
- Settings flow **outward from a hub**. `SettingsClient` requires the consumers it configures (ParkourController, RunController,
  CameraShake, FOVOffset, BlimpCamera, Chrome) and pushes values into each through `apply*Settings`. A new setting means editing
  the hub and the consumer, and the hub's require list grows with every feature.

### 1.9 Content registries share a shape nobody wrote down (NEW)

`MoveRegistryManager`, `RaceManager` and `BloodlineManager` each expose `Validate / List / Get / Upsert / Delete`, and each sits on a
default layer (`DefaultMoveRegistry`, `DefaultBloodlineRegistry`), an authored DataStore layer (`MoveEditorSystem`, `KitEditorSystem`,
which share `AuthoredContentStore`) and, for moves, a shipped-source layer (`AuthoredMoveLibrary`). `EmoteRegistry` (`Exists / Get / GetAll
/ Validate`), `ItemCatalog` and `ArtTreeManager` are a third and fourth shape. Each layer stack is resolved by hand in its own module.
Only moves have `OnChanged`.

### 1.10 Per-player lifecycle and tests are re-scaffolded each time (NEW)

- **46 `[Player]`-keyed tables in 28 server files**, cleared by **47 hand-written `PlayerRemoving`/`BindAllPlayers` handlers**. The
  codebase audit found no leak, but every new System writes this scaffold again. **18** Systems subscribe to
  `PlayerDataSystem.OnProfileLoaded` and **12** poll `IsLoaded`, each with its own "not loaded yet" branch.
- **Client boot has no manifest.** `Main.client.lua` has 47 `boot()` calls in a hand-ordered list. The server has `BootManifest` plus
  `AssertBootComplete`.
- **Tests: 20 specs each define their own `makeDummy` (11) / `makeRig` (7) / `makeCharacter` (3).** 9 specs chain 4-6 `X.Reset()` calls
  in their own order. `TestHelpers/Fixtures.lua` has **0** users. The cohesion audit found that **34 of the 43 red tests were fixture
  drift**: stand-ins missing an API, combatants never registered, identity-less round trips. That is exactly what duplicated rig
  builders produce.
- **Engine-capped resource with no budget:** three modules create their own `Highlight` instances (HitFlash, SwingTellFX,
  AirComboFX). Roblox caps visible Highlights at 31 (inferred risk in a crowded fight, not measured).

### 1.11 Why things get recreated

From git history (168 commits, 83 deleted `src` files) and the memory log, combat, the Move Editor, the admin panel, the character
menu, the hotbar dock, the furnace gauge and four animators were each **rebuilt rather than migrated**. The recurring shape:

1. A canonical module is written beside the old ones, with a header saying it replaces them.
2. The two or three easiest consumers move to it.
3. The session ends. The hard consumers stay on the old path, and the header is now false.
4. The next session finds two systems for one job, trusts neither, and writes a third.

Stuck at step 3 today: AnimationManager, InputRouter, ClientState, Sanitize, ChangeNotifier, the Vessel layer, and `CombatSystem`
(162 stale comment references). §1.5-1.10 add the second cause: **when the shared parts are only parts, building a feature from
scratch is cheaper than finding and assembling them.** The foundations in §2 make "declare it" cheaper than "build it".

---

## 2. The target: ten foundations

Every new feature should be made of **declarations against these**, not new plumbing. Each row names the one module that owns the
job and the existing modules it composes. Nothing here replaces a module that works; each foundation *assembles* the parts that
already exist.

| # | Foundation | Owns | Composes (existing) | Replaces (hand-assembly) |
|---|---|---|---|---|
| F1 | `Shared/Schema.lua` | Declarative decode + validate of untrusted data: `String(max)`, `Number(min,max)`, `Int`, `Enum`, `Array`, `Map`, `Record`, `Optional`, `Default`. `Schema.Decode(shape, raw) -> (value?, reason?)`. NaN-safe by construction. | `Sanitize` (becomes its primitive layer) | ~290 `typeof` checks, 68 NaN checks, per-module `Validate` bodies |
| F2 | `Server/Network/Endpoint.lua` | `Endpoint.Event{ Name, PerSecond, Args = Schema, Admin?, Handler }` / `Endpoint.Function{ ..., ErrorResult }`: creates the remote, rate-limits, decodes args, applies AdminGate, pcall-wraps, logs refusals, and **registers itself with BootManifest** | `NetworkBridge`, `RateLimiter`, `RemoteHandler`, `AdminGate`, F1 | 73 hand-assembled handlers; the hand-kept `BootManifest.Remotes` lists |
| F3 | `Server/Data/ProfileSlice.lua` | Each domain declares its slice: `ProfileSlice.Define{ Key, Schema, Default, Migrations }`. PlayerDataSystem composes the slices for default/copy/encode/decode/migrate, and keeps locking, saving and generations. | F1, `InventoryModel` (the precedent) | `DecodeProfile`'s per-field blocks; edits to PlayerDataSystem for every new field |
| F4 | `Server/Net/PlayerState.lua` + `Client/State/ClientState` | One reliable channel for **a player's own state**. A server domain calls `PlayerState.Publish(player, slice, value)`, deduped by ChangeNotifier. A snapshot goes out on join and on request, so the late-UI pull is solved once. The client mirror is `ClientState.Observe(slice)`. | `ChangeNotifier`, `NetworkBridge`, F1 (client-side decode) | ~10 push+pull channel pairs (§1.7), three private client mirrors, BountyTab's direct remote |
| F5 | `Shared/Combat/BodyRestraint.lua` | "May this body *verb* now", for Attribute-only restraints, from one policy table | `AttributeConstants`, `FrozenBody`, `Invulnerability`, `ParkourOwnership`, `DomainRules` | 7+ consumers' private restraint subsets (§1.3) |
| F6 | `Client/FrameOrder.lua` + `Server/ServerTick.lua` | One named, ordered list of frame slots per side; no two share a value | `CombatTick` (becomes one phase group of ServerTick, or ServerTick's model) | 3 server tickers; 8 clashing client priorities |
| F7 | Body presentation owners: `AnimationManager` (+ `LocalAnimator`), `TransformLayer` (+ absolute claims), `CameraRig` | One owner each for tracks, joint Transforms and camera CFrame, all using claims, the same shape as `RootControl` | existing modules | 3 rogue animators, 3 absolute pose writers, 6 camera writers with flag peepholes |
| F8 | `InputRouter` (finished) + `Client/Settings/SettingsStore.lua` | All input through router layers (`Gameplay`, `Vehicle`, `Menu`, `Debug`, `TextEntry`); debug keys in one table, with a clash check; settings as an observable store that consumers subscribe to | `KeybindManager`, `Chord`, `Analog`, `InputDevice` | ~20 raw input connections, hard-coded flight keys, the settings push-hub |
| F9 | `Server/Content/ContentRegistry.lua` | `ContentRegistry.New{ Kind, Schema, Layers }` with ordered layer resolution (authored > shipped > default), `OnChanged`, `List/Get/Upsert/Delete` | F1, `AuthoredContentStore`, `CallbackList` | Per-kind hand-resolved layer stacks (moves, races, bloodlines; emotes/items later) |
| F10 | `Shared/PlayerScoped.lua` + `Client/Config/ClientBootManifest.lua` + `Tests/TestHelpers/{Rig,CombatHarness}.lua` | Per-player tables that clear themselves on leave and expose a profile-ready gate; a declared client boot order; one rig builder and one ordered combat reset for specs | `PlayerLifecycle`, `BootManifest` (as the model), `WeaponFixture` | 46 tables + 47 leave handlers; 47 hand-ordered client boots; 20 private rig builders and 9 private reset chains |

**Layering rules for the foundations.** `Shared/*` foundations require nothing in `Server/` or `Client/`. F2/F3/F4 server halves
live under `Server/` (F2 needs `AdminConfig`). F5 reads Attributes only and never requires a System. F4 carries **state**, never
**events**: hits, swings, cues and realm messages stay on their existing remotes, reliable or unreliable as they are today.

**Wire and storage compatibility is absolute.** Every existing remote name, payload shape, DataStore key, persisted field name
and `SchemaVersion` stays byte-identical unless an escalation decides otherwise. A foundation that cannot express an existing shape
takes an explicit escape hatch for it (documented in the foundation's header). Never change the shape to fit the foundation.

---

## 3. Spines and workstreams

A **spine** is one session's worth of work. Each workstream inside one ends with every consumer moved, the old path deleted, headers
true, and a gate. A workstream that cannot reach that point is reverted or narrowed, then escalated. It is never left half-converted.

### Spine 0. Baseline and the ownership map (DONE: W0, W1)

- **W0 (done).** Baseline, re-measure, "Who owns what" in `software-architecture.md`.
- **W1 (done).** CallbackList finished (7 converted, 3 justified).

### Spine 1. Safe ground: the test harness (do first; makes every later spine cheaper to verify)

- **W2. `TestHelpers/Rig.lua`.** One R6 rig builder (`Rig.Dummy{ Health?, Attributes?, Parent? }`, `Rig.Character`, `Rig.FakePlayer`
  where the harness allows it), with an Attribute surface and a real `RootJoint` under `HumanoidRootPart`. The cohesion audit found
  one spec looking for it under the wrong part. Migrate the 20 specs' private builders, one folder per commit. Delete
  `TestHelpers/Fixtures.lua`, or give it a user.
- **W3. `TestHelpers/CombatHarness.lua`.** `CombatHarness.Reset()` resets every combat layer **in `CombatTick.PHASES` order**, plus
  WeaponFixture's install-once rule. `CombatHarness.Combatant(rig, weaponId?)` registers a body with every layer that needs it,
  ending the "unregistered combatant" fixture class. Migrate the 9 reset chains.
- Gate: `check-spec-literals.py` gains a rule that fails on a new `local function make(Dummy|Rig|Character)` in a spec.
- Done when the suite's failure set is unchanged (7) and no spec builds its own rig.

### Spine 2. Data contracts: Schema, profile slices, endpoints (highest leverage; strictly in this order)

- **W4. F1 `Schema`.** Build it with `Sanitize` as its number/string primitives, and a spec per combinator, including NaN, ±inf,
  oversize strings, wrong-key maps and metatable'd tables. Convert **`SettingsSystem`'s decoders first** (18 checks, self-contained),
  then `MoveRecordCodec`, then `BloodlineManager`/`RaceManager`/`KitValidation`'s `Validate`. Each conversion has a spec showing
  the old and new decoders give identical results on a corpus (valid record, every single-field corruption, and `nil`).
- **W5. F3 `ProfileSlice`.** Move one slice at a time out of `DecodeProfile`/`CreateDefaultProfile`/`CopyProfile`/`EncodeProfile`
  into its domain: emotes → `EmoteSystem`, arts → `ArtSystem`, bloodlines → `BloodlineSystem`, attributes → `CharacterCreationSystem`,
  settings → `SettingsSystem`, inventory (already a codec) → `InventorySystem`. **Migrations stay keyed by version in one ordered
  chain**: a slice contributes steps; it does not own the version number. Gate: a round-trip spec over a frozen corpus of real-shaped
  v1..vN records (write the corpus *before* the first move), asserting byte-identical `EncodeProfile` output before and after each
  commit.
- **W6. F2 `Endpoint`.** Convert the Systems with the most handlers first (Settings, Emote, Art, Inventory, Bounty,
  CharacterCreation, then combat's `AttackRequestSystem`/`DefenseSystem`/`GrabSystem`, then the dev tools). Endpoint registers
  each remote with `BootManifest`, and the manifest's hand list is deleted once every System is converted; `AssertBootComplete`
  keeps its job. Keep `ServerHopSystem`'s documented `(boolean, string?)` exemption, or give `Endpoint.Function` a multi-return
  form. Gate: `scripts/check-endpoints.py` fails on a bare `OnServerEvent:Connect` / `OnServerInvoke =` outside `Endpoint`.
- Done means: `typeof` checks in server code drop by at least 70%, `x ~= x` checks drop to under 5 (all inside `Sanitize`/`Schema`),
  and no new profile field needs a PlayerDataSystem edit.

### Spine 3. One replicated player state (after Spine 2's W4; needs F1 on the client)

- **W7. F4 `PlayerState` + `ClientState.Observe`.** First write the slice table (§1.7) with each slice's current cadence, size and
  pull path. Then convert one slice per commit, **keeping the old remote alive and firing in parallel** until the client side of that
  slice reads from `ClientState`. Then delete the old remote and its `BootManifest` entry. Order: Qi → MeridianXP → Tier (keep the
  `CultivationTier` Player Attribute: combat reads it), Emote, Bounty marked, Engagement, then the private mirrors (CharacterSheet,
  ArtState, Inventory, WeaponInventory) and BountyTab's board. Each slice keeps its payload type.
- **W8. Client consumers read `ClientState` only.** `CharacterMenuClient`, `InventoryClient`, `WeaponInventoryClient` and `BountyTab`
  stop holding mirrors. Their *actions* (UnlockArt, EquipArt, inventory actions) stay as `Endpoint.Function`s, and the result
  arrives as a state update rather than a bespoke reply where that is already how the UI behaves. Correct `ClientState`'s header.
- Gate: `scripts/check-player-state.py` fails on a `:FireClient(player, ...)` whose remote is declared as a state slice anywhere
  but `PlayerState`.
- **REQUIRES PLAYTEST:** join, open each menu late, die and respawn, rejoin a different server, and watch the bars for one frame of
  defaults.

### Spine 4. Body arbitration (revision 1's W3; parallel with Spine 2 and Spine 3)

- **W9. F5 `BodyRestraint`.** Unchanged from revision 1. **Tabulate first** (verb × restraint, `file:line` per cell, each blank
  marked *deliberate* or *unexplained*), then the pure module plus a policy table, then one consumer per commit, preserving every
  answer and `bodyGate`'s refusal order and reason strings. The record-backed gates (`DefenseSystem.CanAttack`,
  `DamageSystem.CanAttack`, `GrabSystem.CanAttack`, `AirComboSystem.CanAttack`) stay as they are. Each *unexplained* gap becomes an
  escalation. The two candidates already noted are at the end of this doc.

### Spine 5. Frame, camera, pose and animation (revision 1's W4 + W5; REQUIRES PLAYTEST)

- **W10. F6 frame order, both sides.** Client: `FrameOrder` (named slots, no shared values, a "reads what X wrote" line per entry),
  then every `BindToRenderStep` reads its slot from it; bare callbacks move only where a same-frame dependency exists. Server:
  `ServerTick` with phase groups `Movement` (RunSystem, ParkourSystem), `Combat` (CombatTick's PHASES, unchanged) and `World`
  (today's `GameplayEvents.HeartbeatTick` subscribers), preserving today's connection order exactly. Then delete the two bare
  Heartbeats. Gate: `scripts/check-render-order.py`, plus a `ServerTick.Register` assert like CombatTick's.
- **W11. F7 presentation owners.** (a) `CameraRig` with mode claims (`Follow`, `ShiftLock`, `Flight`, `Blimp`, `Scriptable`) and
  additive layers (shake), built only if it removes the flag peepholes with no behaviour change; otherwise stop at the priority
  table and escalate. (b) `TransformLayer` gains *absolute* claims ranked above additive layers, so Grab/Vessel poses and HitFlinch
  stop fighting over `RootJoint`. (c) AnimationManager finished: run the revision-1 spike, then (a) migrate Emote → Flight →
  CombatAnimator into `LocalAnimator` layers, or (b) narrow the header per exception. Delete `AnimationTrackUtil`'s evaluator once
  nothing uses it.
- Playtest checklist: walk, run, armed run, armed idle with a drawn weapon, each emote, take off / cruise / boost / land, hit-stop
  during each, die during each, respawn, lock-on while shift-locked, a blimp pilot taking a hit, an intro camera after respawn.

### Spine 6. Input and settings (parallel with Spines 2-5)

- **W12. F8 InputRouter finished.** Add router layers where they are missing (`Vehicle`, `Menu`, `Debug`, `TextEntry`), then move
  every raw `UserInputService` dispatch onto the router: Grab, Run, ShiftLock, CharacterMenu, Inventory, BugReport, EmoteWheel,
  Onboarding, then Blimp/Boat (shared with W15). **Continuous axis reads** (vehicle throttle, flight) go through `Analog` plus
  `KeybindManager`, not `IsKeyDown`. Text-field focus, drag and scrub inside DevTools/NumericField/TimelineBar are *UI gestures*, not
  actions: they stay raw, listed as exemptions in the router header. **Escalation (default: fix):** flight's hard-coded keys become
  bound actions with a gamepad path. That is a behaviour change, so it is a player decision; see Escalations.
- **W13. One debug-key table.** Move F3/F5/F6/F7/F8 into one `DebugKeys` table with a clash check against `Constants.Keybinds` and
  the gamepad chords. This makes the F6 memory note obsolete.
- **W14. `SettingsStore`.** `SettingsStore.Observe(path, fn)` / `Get(path)`. Consumers subscribe to their own settings, and
  `SettingsClient` keeps persistence, the coalescer and the screen. Its `apply*Settings` functions and its consumer requires are
  deleted. Gate: `SettingsClient` may not require a gameplay module.

### Spine 7. Vehicles finished (revision 1's W2)

- **W15.** `Server/Vessel/VesselMountRegistry` plus a shared `Client/Vessel` helper (new top-level folder → `test.project.json`);
  `ClampLead` shared. Done when each pair's shared-line count is under 40, outside the drive integrator and the mode machine. Vehicle
  input lands on W12's `Vehicle` router layer.

### Spine 8. Content, lifecycle, boot (after Spine 2)

- **W16. F9 `ContentRegistry`.** Write the layer model down first (default / shipped / authored, and which wins, per kind, read from
  source). Then bind moves (`DefaultMoveRegistry` + `AuthoredMoveLibrary` + `MoveRegistryManager` behind one `Get`, the lookup order
  `AttackCatalog` and `MovePresentationSystem` already use), then races and bloodlines. **Persistence is untouched**: the same
  `AuthoredContentStore` fields and DataStore keys. Emotes and items are converted only if the shape fits without an escape hatch.
- **W17. F10 `PlayerScoped`.** `PlayerScoped.New(name)` → a table that clears itself on leave, plus `PlayerScoped.WhenProfileReady(fn)`
  wrapping `OnProfileLoaded`/`IsLoaded` with one "not loaded yet" policy. Convert the 46 tables, one System per commit. Each System's
  leave handler is deleted when it only cleared tables, and kept when it does other work (saves, releases, broadcasts).
- **W18. `ClientBootManifest`.** Declare the client's 47 boots as data (`Name`, `Module`, `After`), and boot it through the existing
  `boot()` wrapper. The order is today's exactly. Add a spec that fails on a client module with a `Start` that is neither in the
  manifest nor listed as manual.
- **W19. Highlight budget.** HitFlash, SwingTellFX and AirComboFX take Highlights from one owner (an `FXPool` lease) with a cap below
  the engine's.

### Spine 9. Guardrails and the cohesion ratchet (draft alongside Spine 1; finish last)

- **W20.** CLAUDE.md, new section **"Extend, migrate, never fork"**. Before creating a module, check the ownership map and the
  foundations table (§2). A replacement module moves every consumer and deletes the old one in the same branch. A from-scratch
  rebuild of an existing feature needs the user's go-ahead and a written migration list. Add the ten foundations as rows in
  CLAUDE.md's shared-module table, as they land.
- **W21. `scripts/cohesion-report.py`.** One script, one table, every ratchet below. Each measure has a stored ceiling and fails if
  it rises. The existing checks stay as they are.

| Ratchet | Now | Target |
|---|---|---|
| Duplicate function bodies (≥6 statements) | 10 | ≤ 4 |
| `typeof` checks in server code | ~290 | ≤ 90 |
| `x ~= x` outside Sanitize/Schema | 68 | 0 |
| Bare `OnServerEvent:Connect` / `OnServerInvoke =` outside Endpoint | 73 | 0 |
| Player-state slices on private remotes | ~10 | 0 |
| Raw `UserInputService` dispatch outside InputRouter + exemptions | ~20 files | 0 |
| Direct restraint-Attribute reads outside BodyRestraint + exemptions | 7+ consumers | 0 |
| Modules sharing a RenderStep priority | 8 | 0 |
| Animators bypassing AnimationManager | 3 | 0, or documented exceptions |
| `[Player]` tables outside PlayerScoped | 46 | 0, or documented exceptions |
| Spec-private rig builders | 20 specs | 0 |
| Headers citing a non-existent module | ≥1 | 0 |
| Modules with no non-spec inbound require | 1 (`HoverLabel`) | 0 |
| Blimp/Boat shared code lines | 370 / 204 | < 40 each |

### Deliberately out of scope

- Every open design escalation from the 2026-10-25 audits (faction, `CombatPowerConstants.Enabled`, the held-hit gate,
  blockcounter, feint lockout, server boot isolation). These are the user's decisions.
- New features, including the progression stubs (Absorb, Awakening, Achievement, Territory, World, Faction). The foundations make
  them cheaper to build later; building them is not this plan.
- The frozen combat feel skeleton. No workstream changes a timing, window, cap or cooldown.
- Changing any wire name, payload shape, DataStore key or persisted field name (§2).
- Mixing renames with structure. A rename (`Roll` → `Evade`) gets its own commit.

---

## 4. Order and parallelism

```
Spine 0 (done)
   │
Spine 1 (harness) ──┬── Spine 2 (Schema → ProfileSlice → Endpoint) ── Spine 3 (PlayerState) ── Spine 8 (content, lifecycle, boot)
                    ├── Spine 4 (BodyRestraint)
                    ├── Spine 6 (input, settings) ── Spine 7 (vehicles)
                    └── Spine 5 (frame, camera, pose, animation; last of the client spines; playtest)
Spine 9 drafted with Spine 1, finished after everything else.
```

Spines 2, 4 and 6 touch disjoint files and can run as **parallel sessions in separate worktrees**. Spine 3 needs W4's `Schema` on the
client. Spine 7 needs W12's `Vehicle` layer. Spine 5 goes last on the client, because it shares HitStop, the pose FX, ShiftLock and the
frame order with Spines 4 and 6. CLAUDE.md and `software-architecture.md` are append-only for every session. Spine 9 owns their
final wording.

## 5. Done means

The game is cohesive in this sense when **adding a typical feature is only declarations**. Take an "Absorb" feature: its profile
field is a `ProfileSlice`, its requests are `Endpoint`s with a `Schema`, its HUD value is a `PlayerState` slice the UI `Observe`s, its
gates are a `BodyRestraint` verb, its per-player bookkeeping is `PlayerScoped`, its frame work is a `ServerTick` phase, its input is a
router binding, and its specs build rigs through `Rig`. The feature should need **no edit** to PlayerDataSystem, BootManifest,
SettingsClient, ClientState's bootstrap or any other domain's file. Every ratchet in W21 is at or below target.

---

## Status (pass of 2026-10-25)

Scope of this session: W0 and W1 only. W2-W6 are **not started**. (Revision-1 numbering: revision 1's W2-W6 are revision 2's W15,
W9, W10-W11 and W20-W21.)

| Workstream | State | Commits |
|---|---|---|
| W0 | done | `851df76` re-measure and correct the plan; `f67e5ca` "Who owns what" in `software-architecture.md` |
| W1 | done | `b33aecd` DefaultMoveRegistry; `68ebfaf` MoveRegistryManager; `4304e6e` HotbarBindings; `3e69cfd` InputDevice; `4f0473f` KeybindManager; `3e46878` ParkourSystem; `d0173ef` GameplayEvents; `4f929c8` Logger + CombatAnimator header notes; `965ad45` CLAUDE.md row + MovePresentationCatalog note |
| W2-W6 | not started | |

**W1 detail (read from source, then ran the suite).**
- Converted to `CallbackList` (6 planned + 1 judged): `DefaultMoveRegistry.OnChanged`, `MoveRegistryManager.OnChanged`,
  `HotbarBindings.OnChanged`, `InputDevice.OnChanged`, `KeybindManager.OnChanged`, `ParkourSystem.OnActionStarted`, and
  `GameplayEvents.OnHeartbeatTick`. Every public signature is unchanged.
- Kept hand-rolled, each now justified in its own header: `Logger.entryListeners` (CallbackList requires Logger, and its
  error path would re-enter `emit`), `CombatAnimator.perLifeResetHandlers` (private closers, not an extension point,
  deliberately unguarded), and `MovePresentationCatalog`'s `listeners` (found by grep, not in the plan: dispatches with
  `task.spawn`, CallbackList is synchronous).
- `:Clear()` wired only into `DefaultMoveRegistry.ResetCache`, the one spec-only reset that exists. Not wired elsewhere on
  purpose: `MoveRegistryManager.Init` is the boot entry and every spec's reset, and its subscribers (DomainSystem,
  MovePresentationSystem) live for the VM; the others (HotbarBindings, InputDevice, KeybindManager, ParkourSystem) have no
  reset to hook.
- Behaviour differences, all deliberate and small: a throwing subscriber to DefaultMoveRegistry/HotbarBindings/InputDevice/
  KeybindManager was silently swallowed or aborted the dispatch and is now caught and logged by CallbackList;
  `MoveRegistryManager`'s "OnChanged listener failed" warning is now CallbackList's `error` line; `GameplayEvents` heartbeat
  subscribers now run in connection order (before: `pairs` over token keys, unspecified, though the header claimed boot
  order); the "Heartbeat tick subscriber errored" log line now reads "A GameplayEvents.OnHeartbeatTick consumer errored".
- Three logger scopes added to `DebugConstants` (`DefaultMoveRegistry`, `HotbarBindings`, `InputDevice`).

**Measured.** CallbackList inbound requires 11 -> 18. Duplicate-body `TOTAL` 11 -> 10 (the five identical `OnChanged`
bodies are gone; one group, of 5, fell away). Hand-rolled lists: 0 unjustified.

**Suite.** Baseline (W0, before any change): 3538 passed / 7 failed. After W1: 3538 / 7. The failing set is identical by
assertion fingerprint (1x `"Cooldown"` vs `"NotInWindup"`, 1x `nil` vs `"ChainDelay"`, 5x `true` vs `false`). Names: the printed
tree truncates after `Combat`, so only the two `AttackRequestSystem -- feint` specs are named by the tree
("abandons the string and allows a fresh Heavy once the recovery ends", "will not feint again inside the feint cooldown");
the other five match the previously recorded TrainingBot failures by count and shape, not by name read in this run.

**Gates.** `selene src/` 0 errors / 2 warnings (the known pair). `check-logger-scopes` ok (181 scopes), `check-live-project` ok,
`check-single-writers` ok, `check-spec-literals` ok, `check-stale-refs` ok. `stylua`: no formatting difference on any touched
file once CR is ignored (plain `--check` fails on the CRLF checkout, as CLAUDE.md warns). Not run: the planned new gates
(they belong to W6).

**Files created:** none. **Files deleted:** none. **Headers corrected as false:** none in W1. Plan §1 numbers corrected in W0
(see the W0 note at the top).

**Not verified.** Nothing from W1 needs a playtest beyond the suite, but these were not exercised by it: a HUD/hotbar rebuild
and a glyph refresh after a rebind or device switch (listener plumbing only; confirm in Studio that rebinding a key updates
the on-screen glyph), and the Move Editor's catalogue push after an edit (MovePresentationSystem listens to both registries).

## Status (Spine 1, 2026-10-25)

Scope of this session: Spine 1 (W2, W3) only. Studio was closed (`tasklist | findstr RobloxStudio` empty). Nothing pushed.

**Baseline re-measured before any change (ran):** 3538 passed / 7 failed, identical to the W1 number. Failing set, by assertion
fingerprint and by the tree's named failing nodes: the two `AttackRequestSystem -- feint` specs, plus five `true` vs `false`
(the TrainingBot ones, matched by shape; the tree truncates after `Combat`).

| Workstream | State | Commits |
|---|---|---|
| W2 `Rig.lua` + spec migration | done | `5710987` Rig + CombatHarness + specs; `76012c2` Defense, `3705b4f` Damage, `cbd24b6` Domain, `4791bca` Engagement, `4f88e8e` Grab, `f88080c` HitboxEngine, `da03ab5` Attack, `c3a3d04` TrainingBot, `8b6f5a3` Weapon, `3d1482e` Admin, `3587ef7` FX, `215dd09` Parkour; `a7645f7` delete `Fixtures.lua` |
| W3 `CombatHarness.lua` + reset chains | done | same commits; the gate is `f20027c` |
| W20 draft | done (draft, for Spine 9 to finalise) | `e93f158` appended to CLAUDE.md |

**What moved (read from source, then ran the suite).**
- **22 specs, not 20, had a private rig builder.** The plan's grep (`makeDummy`/`makeRig`/`makeCharacter`) missed two that did the
  same job under other names: `TrainingBotSystem.spec` `makeOpponent` and `DebugDummySystem.spec` `makeAttacker`. Both moved.
  `GrabSystem.spec` also had a second builder (`makeR6`). Counted by the gate's rule at `7810df6`: 22 files; now 0.
- **Reset chains: 11, not 9.** DefenseSystem, Knockback, Grab, Engagement, DomainStrike, AttackRequestSystem, DamageSystem,
  ProjectileDefense, TrainingBot, DebugDummy now use `CombatHarness.Reset`/`Teardown`. WeaponInventory's chain moved too. The
  engine-only specs (HitboxEngine, Projectile), DomainSystem and WeaponVisual keep a single layer reset on purpose (they never
  touched the others) and use `Rig.DestroyAll` only.
- `Rig`: `Dummy`, `Character`, `R6`, `Limbs`, `Bare`, `FakePlayer`, `Track`, `DestroyAll`. `CombatHarness`: `Reset`, `Teardown`,
  `Combatant`, `Spawner(layers, bodyOptions?)`. `Reset` walks `CombatTick.PHASES` and asserts every phase has a reset, so a new phase
  fails loudly. It resets `ParryWindows` with the defense layer and never calls `WeaponFixture.Install/Remove/Rebuild`.
- The old chains reset top-down (Damage, Defense, Engine); the harness resets in frame order (Engine first). Safe because every
  cross-layer subscription is a `CallbackList` disconnect, idempotent after the owner's `:Clear()` (read from `CallbackList.lua`), and
  the suite confirms it.
- Deleted from the specs: every private builder in those 22 files, about 20 `spawned`/`rigs`/`registered` tables with their destroy loops, 11 reset chains,
  `Parkour`'s private `Rig` type, `R6_LIMBS`. Parkour specs now read `rig.Model`/`rig.Root` (were `rig.Character`/`rig.RootPart`); every
  assertion is unchanged.
- Left alone on purpose, not rigs: `SwingSequencer`/`ComboEscalation` `makeAttacker` (a bare Model a module keys by),
  `CandidateGatherer` `makeBody` (a hurtbox-gather fixture with accessory and weapon), `AttackWindows` (Poses), and the lone-`Humanoid`
  fixtures in `RootControl`, `MovementAllowance`, `DomainRules`, `ParkourOwnership`. None has both a `HumanoidRootPart` and a Humanoid
  built in the spec, which is the gate's second rule.
- **Gate.** `check-spec-literals.py`: no `local [function] make(Dummy|Rig|Character|R6|Opponent)` in a spec, and no spec that names a
  `HumanoidRootPart` and instances a `Humanoid`. Both skip `TestHelpers`. Verified red on a planted builder and green on the tree. (My
  first version of the edit wrote a literal backspace for `` and passed vacuously; the plant caught it and it is fixed in `f20027c`.)
- `TestHelpers/Fixtures.lua` deleted: zero requirers in `src`, `scripts` and the specs (the `Tests/Fixtures/` data folder is a different
  thing and untouched).

**W21 ratchet moved (measured, `7810df6` to `HEAD`).** Spec-private rig builders: **22 specs -> 0**. Inbound requires (grep over `src`): `Rig` is
required by 18 specs plus `CombatHarness`; `CombatHarness` by 14 specs.

**Suite (ran).** Baseline 3538 passed / 7 failed. Final 3554 passed / 7 failed. The +16 are the two new helper specs (`Rig.spec`,
`CombatHarness.spec`). The failing assertions are the same 7 in the same order, and the tree's `[-]` nodes diff identical to the
baseline's. No spec lost or gained an assertion through conversion. One transient: a run taken while I ran selene/stylua showed an
extra `AnimationFreezeGuard.spec:197` failure (`1` vs `1.25`, a wall-clock `task.wait` window); it did not recur in the next four
runs, and that spec was not touched.

**Gates (ran).** `selene src/` 0 errors / 2 warnings (the known `UDim2.fromScale` pair). `stylua`, CR ignored, on every touched file:
clean. `check-logger-scopes` ok (181), `check-live-project` ok, `check-single-writers` ok, `check-spec-literals` ok, `check-stale-refs`
ok. No new `Logger.scope`. `rewrite detector`: the largest per-file change is `DefenseSystem.spec` (+108/-144 of ~1300 lines,
mostly the 104 `makeDummy(` -> `spawnDummy(` call-site renames the deletion forces); nothing lost 60%.

**Files created:** `Tests/TestHelpers/Rig.lua`, `Rig.spec.lua`, `CombatHarness.lua`, `CombatHarness.spec.lua`. **Files deleted:**
`Tests/TestHelpers/Fixtures.lua`. **Docs appended:** CLAUDE.md (draft W20 section and the two helper rows).

**Headers corrected as false:** none. Rig's and CombatHarness's headers were written to match the code, including the opt-in root joint
(E2).

**Not verified.** (1) Order-independence beyond the one fixed spec order TestEZ uses: to check, re-run the suite once with a
spec renamed so it sorts first (for example the `CombatHarness` spec), since `CombatHarness.Reset` now clears layers some specs
used to leave. (2) The `AnimationFreezeGuard` timing spec under load: run the suite twice on an idle machine. (3) `Rig.Bare` and
`Rig.Dummy` in `Admin`/`WeaponVisual` specs replaced unparented/one-off models with tracked ones; nothing a player sees. No gameplay
code changed, so no playtest is needed for this spine.

## Status (W6 finished, 2026-10-26)

Scope: the last of W6. Every server remote now goes through `Endpoint`; nothing committed.

- **Handlers converted (42 -> 0 outside Endpoint):** BlimpSystem (5), BoatSystem (4), LiveConsoleSystem (2), KitEditorSystem (10,
  admin), MoveEditorSystem (15, admin), AttackRequestSystem (Request, Feint), DefenseSystem (SetBlocking), GrabSystem (Throw),
  DomainSystem (Request -- it was connected through a Trove, which the first count missed).
- **Push-only remotes moved onto `endpoint.Push`:** Damage, Engagement, EnvironmentReaction (incl. the unreliable cosmetic), Meridian,
  PlayerDeath, Qi, ResourceGathering, Tier, and every push in the Systems above. `NetworkBridge.Create*` now appears only in
  Endpoint and ServerHopSystem.
- **Endpoint extended, not forked:** an Event's `Bound` carries its `Connection`, so DomainSystem's `Stop` still disconnects it.
- **New buckets where a remote had none** (Endpoint requires one): `BlimpConstants.Network.MaxMountQueryPerSecond` (GetCurrentMount,
  once per boot), LiveConsole Unsubscribe and MoveEditor SetEditorOpen each on a bucket of their own, so a "stop"/close is never
  starved by the System's other traffic. Their ceilings are far above a human; the close-exempt intent of both is kept.
- **Gate:** `scripts/check-endpoints.py` (exempt: Endpoint, ServerHopSystem). Ratchet: bare handlers 73 -> 0.
- **Lint:** selene 0 errors; the 2 remaining warnings are in `Client/UI/Screens/Inventory/init.lua` (not touched here).

**Not done.** (1) The BootManifest hand lists (`Remotes = namesOf(...)`) are still there. Every remote is now ALSO declared by
Endpoint, so they are redundant at boot, but `BootManifest.spec` reads them statically (Dev Menu / Move Editor tables "accounted for",
"one owner") without Initing any System; deleting them needs those cases rewritten to a declared-at-Init form. (2) **Suite not run**:
Studio was open, and run-in-roblox would have run inside the playtest. Run it with Studio closed; baseline is 3538 / 7.
(3) Behaviour to check in a playtest: an admin opens/closes the Move Editor (freeze/unfreeze), the F5 console, a blimp mount after
rejoin (GetCurrentMount), a realm snapshot request after a Stop/Init cycle.

## Status (W17, W13, W21 and W6 close-out, 2026-10-26)

**Suite (ran, Studio closed):** after W6 and again after this pass, 7 failed -- the identical baseline set (feint x2, TrainingBot x5).
The two new specs (`Shared/PlayerScoped`, `Input/DebugKeys`) pass.

- **W6 close-out, decided:** the BootManifest `Remotes = namesOf(...)` lists STAY. They are derived from Constants tables (not
  hand-typed), and they are the only record of names a CLIENT waits on; comparing them with Endpoint's declarations is what catches
  a name nobody creates. The plan's "delete the hand list" step is withdrawn; BootManifest's DeclareRemote comment says why.
- **W17 PlayerScoped (done, narrowed):** `Shared/PlayerScoped.lua` (`New`, `Adopt`, `Release`, `Count`; the clear is deferred past
  PlayerRemoving). RateLimiter's buckets are scoped, so every `limiter:Clear(player)` on leave is gone. 25 tables in 18 Systems
  converted; 15 leave handlers deleted outright, the rest keep only their real work (dismounts, releases, invisibility). LEFT AS
  EXCEPTIONS (18 tables, the report's ceiling): PlayerDataSystem (its save yields, then reads), Engagement/Rivalry/Bounty/PlayerDeath/
  KnockbackAudit (their release scrubs the leaver out of OTHER players' rows), LiveConsole subscribers (a counter moves with it),
  Blimp/Boat mounts (dismount reads them). `WhenProfileReady` was not built: the profile gate is server-only and stays on
  PlayerDataSystem.
- **W13 DebugKeys (done):** `Shared/Input/DebugKeys.lua` holds F3/F6/F7; DebugConstants and ParkourConstants read from it;
  `Clashes()` checks them against each other, `Constants.Keybinds` (F5, F8 live there) and engine keys; asserted by a spec.
- **W21 cohesion report (done):** `scripts/cohesion-report.py` + `scripts/cohesion-ceilings.json`. Baseline 2026-10-26:
  typeof_server 228 (target 90), nan_checks 61, bare_remote_handlers 0, raw_input_files 23, shared_render_priority 7,
  unscoped_player_tables 18, load_animation_bypass 6, spec_rig_builders 0, duplicate_functions 11 (target 4), stale_combatsystem 161.
  Not yet measured (their foundations do not exist): restraint reads (W9), state slices on private remotes (W7), Blimp/Boat shared lines (W15).

**Not started:** W7-W8 (PlayerState), W9 (BodyRestraint), W10-W11 (frame order, presentation owners), W12 (InputRouter), W14
(SettingsStore), W15 (vessels), W16 (ContentRegistry), W18 (ClientBootManifest), W19 (Highlight budget). Spines 3, 5, 6 and 7 need a
playtest to finish; see section 3.

## Status (every remaining spine, 2026-10-27)

**Suite (ran after each spine, Studio closed):** 7 failed every time -- the identical baseline set (feint x2, TrainingBot x5). New
specs, all passing: `Combat/BodyRestraint`, `Data/ContentRegistry`, `Server/PlayerStateSystem`, `Client/SettingsStore`,
`Client/FrameOrder`. Gates: selene 0 errors (2 pre-existing Inventory UI warnings), check-endpoints, check-single-writers,
check-live-project, check-spec-literals, check-client-boot (new), cohesion-report: all pass. Nothing committed.

| W | State | What |
|---|---|---|
| W9 BodyRestraint | done | `Shared/Combat/BodyRestraint.lua`, 11 verbs, 12 consumers moved (bodyGate, evade, guard press + remote, RunSystem mirror, HeldElsewhere, AttackInputClient, LockOn, Emote x2, MovementGuard, AirComboSystem); `FrozenBody.lua` deleted. Proven over 512 flag combinations. Matrix + escalations E1-E6: `2026-10-27-body-restraint-matrix.md` |
| W16 ContentRegistry | done, narrowed | `Server/Data/ContentRegistry.lua` + `Server/Combat/MoveContent.lua`; AttackCatalog, MovePresentationSystem, MoveEditorSystem, AttackRequestSystem moved. Races/bloodlines are one table each and were not bound (escalation C1). `2026-10-27-content-layers.md` |
| W7 PlayerState | done | `Server/Systems/PlayerStateSystem.lua` (+ `PlayerState_Replay`), 11 slices registered; wire names and payloads unchanged |
| W8 ClientState only | done for the sheet, inventory, weapons and bounty board | `ClientState.Observe/Latest` cache every slice; CharacterMenuClient, InventoryClient, WeaponInventoryClient and BountyTab read it. `Character_GetSheet` and `Bounty_GetActiveBounties` DELETED. The art catalogue pull stays (it is content, not player state) |
| W12 InputRouter | done, narrowed | 7 panel toggles + ShiftLock + Grab + Sprint on the router; `InputRouter.BindDebugKey` for F3/F6/F7. Remaining raw sites are named exemptions in cohesion-report (UI gestures, rebind capture, Escape owner, emote wheel, onboarding hold, Move Editor shortcuts, and Blimp/Boat -- which wait on a Vehicle layer with their ButtonA quirk). Flight is still escalation E1 |
| W13 DebugKeys | done (previous pass) | |
| W14 SettingsStore | done | `Client/Settings/SettingsStore.lua`; ParkourController, RunController, CameraShake, FOVOffset, BlimpCamera, Analog subscribe themselves; SettingsClient's apply* bodies only publish, and it requires no gameplay module |
| W15 Vessels | partial | `Server/Vessel/VesselContacts.lua`, `VesselWorldEntry.lua`; Blimp/Boat server shared lines 356 -> 297 (ratchet `vessel_shared_lines` 413 incl. the controllers). The rest is mount bookkeeping keyed on `.Blimp`/`.Boat` record fields; a VesselMountRegistry needs one record shape and a playtest |
| W17 PlayerScoped | done (previous pass) | |
| W18 ClientBootManifest | done | `Client/Config/ClientBootManifest.lua` (47 booted, 16 started by owners), `boot()` marks, end of boot logs drift, `scripts/check-client-boot.py`. Order stays in Main.client.lua, as on the server |
| W19 Highlight budget | done | `Client/FX/HighlightBudget.lua`, cap 24; HitFlash, SwingTellFX, AirComboFX (x2) acquire from it; ratchet `highlight_bypass` = 0 |
| W10 FrameOrder (client) | done, values unchanged | `Client/Config/FrameOrder.lua`, all 19 bindings read it; 4 known clashes pinned by a spec; separating them is a playtest change (`2026-10-27-frame-order.md`) |
| W10 ServerTick | not built | escalation in `2026-10-27-frame-order.md`: it would define, not preserve, an order that is connection order today |
| W11 presentation owners | not built | escalations P1 (CameraRig), P2 (absolute Transform claims), P3 (AnimationManager header is false; three animators bypass it) |
| W20/W21 | W21 extended | cohesion-report now measures 14 things; `typeof_server` counts runtime checks only (208) |

**REQUIRES PLAYTEST before this branch ships** (nothing here was seen in a running game): join and open the character menu,
inventory, weapon dock and bounty tab late (W8); every panel toggle key, F3/F6/F7, shift lock, grab throw, sprint hold and toggle
(W12); every settings toggle in the Settings screen, especially comfort and gamepad (W14); mount, ride, dismount and walk off a blimp
and a boat, and drag a tagged hull into the world at runtime (W15); a crowded fight with hit flashes, swing tells and an air combo
(W19); a frozen, grabbed, mounted and flying player trying to swing, guard, evade, emote and lock on (W9 -- the answers should be
unchanged).

## Escalations

### E1. Flight ignores rebinds and has no gamepad path  (W12)
Found: `FlightController.lua:247-263` reads `IsKeyDown(W/A/S/D/Space/LeftControl)` directly; the file has no `Analog`/gamepad reference.
Option A: bind flight to router actions with a gamepad axis. Consequence: rebinds apply to flight; a controller player can fly. Effort: M.
Option B: keep it. Consequence: flight stays keyboard-only, on the default keys only.
Blocks: W12's "0 raw dispatch" target for `FlightController`.

Candidate escalations for W9, carried from the W0-W1 session (not changed there): `RunSystem` honours `Hitstun`, `GrabThrowing`
and realm rooting while `bodyGate` does not read them directly (they arrive through the record-backed gates); `ParkourController`
does not read `Mounted` or `Grabbed` and relies on `RootControlLocked`.

### E2. `Rig` does not give every Dummy a RootJoint by default  (W2)
Found: the plan says `Rig` builds a Dummy "with a real `RootJoint` under `HumanoidRootPart`". `HitboxEngine`'s hurtbox gather indexes
a body's root plus its direct-child BaseParts (`CandidateGatherer`), so a default Torso would add a second hurtbox to every dummy in
the 22 migrated specs and change what their hit assertions see. `Rig.lua` header; `Rig.Dummy` option `RootJoint`.
Option A: make `RootJoint = true` the default — consequence: every combat spec's dummy gains a Torso hurtbox, so contact counts and some positional assertions may shift; each would need re-baselining against the 7 red; effort: M.
Option B: keep it opt-in; `Rig.R6` is the default real-joint body (the joint sits under `HumanoidRootPart`, checked by `Rig.spec`) — consequence: a spec that needs a joint asks for `RootJoint = true` or `Rig.R6`; effort: S (done).
Blocks: nothing.
