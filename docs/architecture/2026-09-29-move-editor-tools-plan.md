# Move Editor tools — build plan (2026-09-29)

**Audience:** the agent building this. Everything here was verified against source on 2026-09-29, the
same day the Move Editor was rebuilt from nothing — read `docs/design/move-editor-guide.md` first, then
this. Re-verify any line you are about to depend on; the tree moves fast.

> **STATUS (2026-09-29, end of day): BUILT — all of Phases 0–7.** Phase 0 results are under Phase 0;
> where the build departed from this text, and why, is in **§11 As built** at the end (Phase 1's are also
> inline under 1.3). This document is now the record of the design; `docs/design/move-editor-guide.md` is
> how to use it. Section 9's playtest checklist has NOT been run yet.

**Scope, as requested by the owner:**

1. Frame data + balance numbers in the readout.
2. The clip's strike marker on the timeline + a "Match timing to clip" button.
3. The hitbox drawn on your own character in the world, live — **and** direct placement: drag it where
   it should spawn (move / rotate / resize handles).
4. Test-bench controls: dummy guard, a sparring bot by style (incl. a parrying one), clear-all.
5. A hit log for test swings.
6. Undo / redo.
7. Bulk-edit a group (e.g. "all Sword Basics +10% windup, −5% damage").
8. Version history per move, with restore.
9. **Studio only:** write a move into the game's SOURCE (a real `.lua` file under `src/`, synced by Rojo,
   shipped with the build) instead of the DataStore.

Out of scope: templates, compare/ghost overlay, multi-admin presence, keyboard move navigation.

---

## 0. Ground rules (read before any phase)

- **CLAUDE.md applies in full.** Shared-module table (Trove, PlayerLifecycle, Selection, Stack/Layer/Inset,
  Fade, NetworkBridge, RateLimiter, RemoteHandler, DataStoreRetry, Logger…). No hand-rolled versions.
- **UI ideology** (`docs/ui-ux-philosophy.md`, `Components/ScreenFrame.lua` header): no cards/boxes inside
  bands, bronze `SectionHeading` + spacing for groups, `Tokens` only (no `Color3.fromRGB` in screens),
  every interactive element wires `Selection` (gamepad), `Button` with `Variant` peeks its text ONCE (use
  the legacy path, `Variant = nil`, for live text).
- **Every new remote** goes in `Constants.MoveEditor.RemoteNames` (`Shared/Authoring/EditorConstants.lua`)
  and is created in `MoveEditorSystem.Init`. `BootManifest` reads that table via `namesOf`, so a name
  added but never created FAILS the boot check — create every one, even Studio-only ones (they refuse
  outside Studio instead of not existing).
- **Every handler**: `gate(player, actionName)` (AdminGate + the System's limiter) first, shape-check
  every argument (`typeof`), return `{ Success, Reason? }`. Reasons are stable codes; add each new one
  to `Screens/DevTools/MoveEditor/Copy.lua`'s `FAILURES`.
- **Server computes, client renders.** Anything that needs clip data, a server-only module
  (`DamageResolver`, `GuardMeter`), or trusted state is computed in `MoveEditorSystem` and shipped on the
  entry (`MoveEditorTypes.MoveEntry`). Do not duplicate server formulas on the client.
- **Gates per phase:** `selene src/` 0/0; `stylua` + `stylua --check` on touched files only (CRLF churn —
  see CLAUDE.md); new top-level folders need `test.project.json` entries; run the TestEZ suite
  (**never while the owner's Studio is open** — check `Get-Process RobloxStudioBeta` and ask); strip the
  `ParkourConstants.lua` BOM before building. Roblox property names are unchecked by lint — anything new
  touching Instances (Handles, parts) needs a playtest.
- **Do not add a field no runtime reads.** That is how the previous editor died.

### Correction to ship in Phase 1 (found while planning)

`Copy.Hints.PostureDamage` currently says posture damage is "guard drained on a blocked hit". **Wrong.**
`Server/Combat/Damage/DamageResolver.Resolve`: on **Clean/Backstab** hits `GuardDrain = PostureDamage ×
DamageConstants.Guard.PressurePerPostureDamage (× Backstab.Multiplier)`, applied through
`DefenseSystem.DrainGuard` — i.e. posture damage is guard pressure on an UNGUARDED hit. A **blocked** hit
drains `DefenseConstants.Guard.DrainPerPowerLevel × PowerLevel` (`GuardMeter.DrainFor`, ×
`Stagger.GuardDrainMultiplier` if the blocker is staggered) and deals no damage. Fix the hint to:
"Guard pressure a clean hit adds. A BLOCKED hit drains by power level instead." Also fix
`Copy.Hints.PowerLevel` to say "sets how much guard a blocked hit drains (18 per level)" — read the 18
from `DefenseConstants.Guard.DrainPerPowerLevel` at build time, don't hardcode it in the string.

---

## Phase 0 — two spikes. Do these FIRST; later phases depend on the answers.

**0a. Can a Studio play-mode SERVER script POST to `http://localhost`?** Phase 7 depends on it.
Throwaway script in `ServerScriptService` during a Studio playtest with Game Settings → Security →
"Allow HTTP Requests" ON: `HttpService:RequestAsync({ Url = "http://localhost:34880/health", Method =
"GET" })` against `python -m http.server 34880`. Record the result in this doc.
- Works → Phase 7 as written.
- Refused → Phase 7 ships only its **Export** path (the generated source shown in a copyable text box);
  the one-click write is dropped. Everything else in Phase 7 (generator, loader, shipped layer) still
  ships.

**0b. Do `Handles` / `ArcHandles` work at runtime from a LocalScript?** Phase 4's placement depends on it.
Parent a `Handles` (Style = Movement, Adornee = a client-created anchored Part) to `PlayerGui` and
confirm `MouseDrag` fires. Expected yes (they are GuiBase3d adornments). If not, Phase 4 placement falls
back to keyboard nudging only (arrow keys / PageUp/Down move the offset by the snap step, Q/E yaw).

### Phase 0 results (owner's Studio playtest, 2026-09-29)

**0a: WORKS → Phase 7 is built as written.** A play-mode server Script (Allow HTTP Requests ON) got
`200` from a stdlib Python server bound to `127.0.0.1:34880` for all four of: `GET http://localhost`,
`GET http://127.0.0.1`, `POST http://localhost` (JSON body), `POST http://127.0.0.1`. So Studio resolves
`localhost` to the IPv4 bind, and the helper does NOT need to also listen on `::1`.
`HttpService.HttpEnabled` is readable from a server Script (it returned `true`), so `WriteToSource` can
report `HttpDisabled` by reading it up front rather than parsing an error string.

**0b: WORKS → Phase 4 placement uses real handles.** From a LocalScript, with the `Handles`/`ArcHandles`
parented to `PlayerGui` and adorning a client-created anchored Part under `workspace.CurrentCamera`,
both `MouseButton1Down` and `MouseDrag` fired with sane arguments (`Handles`: face + signed distance
along that face's normal, relative to the drag start; `ArcHandles`: axis + angle). Two findings the
Phase 4 code must honour:

- **`ArcHandles.MouseDrag`'s `relativeAngle` wraps by 2π mid-drag.** One continuous drag on Axis.Y logged
  `…0.096, −6.071, −5.817…` and later `…2.58, −3.69, 2.59, −3.68…` (the same pose reported on both
  sides of the wrap, alternating frame to frame). Using it raw snaps the volume through a full turn.
  Unwrap it: keep the previous raw angle, add `((raw − prev + π) % 2π) − π` to an accumulator. That
  accumulator is the drag's angle. `HitboxWorldPreview` owns this, and it is covered by a pure spec
  (`unwrapAngle`).
- **The mouse must be freed explicitly.** The game's camera (`ShiftLockCamera`) can hold the mouse
  locked, and a locked cursor cannot grab a handle. The spike forced `MouseBehavior = Default` +
  `MouseIconEnabled = true` from a `BindToRenderStep` at `Last + 1` for the whole session. Placement
  mode does the same while it is active (and only then), unbinding on exit.

---

## Phase 1 — Frame data, balance numbers, strike marker, match-to-clip

### 1.1 `Server/Systems/Support/MoveBalance.lua` (new, pure, specced)

```lua
export type Balance = {
	FrameRate: number,                 -- Constants.MoveEditor.FrameRate (add: 60)
	StartupFrames: number,             -- round(Windup * FrameRate)
	ActiveFrames: number,
	RecoveryFrames: number,
	TotalFrames: number,               -- Startup + Active + Recovery
	CooldownFrames: number,
	OnHitFrames: { Min: number, Max: number },
	OnBlockFrames: { Min: number, Max: number },
	HitsToKill: number,                -- ceil(MaxHealth / Damage) at combo stage 1; math.huge if Damage == 0
	StringHitsToKill: number,          -- hits needed if each successive hit is one combo stage deeper
	BlockedHitsToBreakGuard: number,   -- ceil(Guard.Max / GuardMeter.DrainFor(powerLevel, false))
	StaggeredBlocksToBreakGuard: number,-- same with staggered = true
	CleanHitsToBreakGuard: number,     -- ceil(Guard.Max / (PostureDamage * PressurePerPostureDamage)); huge if 0
	DamagePerSecond: number,           -- Damage / max(Total seconds, Cooldown)
}
function MoveBalance.Compute(effective: MoveEditorTypes.EffectiveTiming, move: MoveTypes.MoveDefinition): Balance
```

Inputs are the REAL modules, never copies of their numbers:
- `DamageConstants.Hitstun.Seconds` (0.65 today — flat, per `DamageResolver`).
- `DamageResolver.ComboMultiplier(stage)` (server) for `StringHitsToKill`: loop stage = 1..`Combo.MaxStage`
  (then stay at max), accumulating `Damage × ComboMultiplier(stage)` until ≥ MaxHealth.
- `GuardMeter.DrainFor(MoveTypes.PowerLevelOf(move), staggered)` (server, `Combat/Defense/GuardMeter.lua`).
- `DefenseConstants.Guard.Max`, `DamageConstants.Guard.PressurePerPostureDamage`.
- MaxHealth: `CombatConstants.MaxHealth` (100 — the player pool; dummies/bots use 500, not the reference).

Frame advantage, with contact assumed on the FIRST active frame (worst case for the attacker) for `Min`
and the LAST active frame ("meaty") for `Max`:
- `OnHit.Min = round((Hitstun − (Active + Recovery)) × FR)`, `OnHit.Max = round((Hitstun − Recovery) × FR)`.
- **There is no blockstun in this game** (a Blocked contact applies none — `DamageResolver`). So
  `OnBlock.Min = −round((Active + Recovery) × FR)`, `OnBlock.Max = −round(Recovery × FR)`: how long the
  attacker is still committed after a block, which the blocker can punish. Say so in the UI caption.
- Use the **effective** timing (post clip sync), never the authored one.

### 1.2 Strike marker + match-to-clip, on the entry

Extend `MoveEditorTypes.EffectiveTiming`:
```lua
	-- The clip's strike marker (Hit / AttackM<n>) in swing time, or nil when it has none or is unread.
	StrikeSeconds: number?,
```
and `MoveEntry`:
```lua
	Balance: MoveBalance.Balance?,   -- nil when Effective is nil (typed via a MoveEditorTypes mirror type)
	-- Authored numbers that make the authored timeline equal the clip-synced one. nil when the clip's
	-- length or marker is unknown.
	ClipMatch: { WindupSeconds: number, RecoverySeconds: number }?,
```
(Put `Balance`'s TYPE in `MoveEditorTypes` — the client must name it; `MoveBalance.lua` is server-only and
returns that type.)

Compute in `MoveEditorSystem.effectiveTiming` / `buildEntry`. Formulas, derived from
`AttackCatalog.Get` step by step (verify against it before coding — if AttackCatalog changes, these do):
- `marker = AttackWindows.WindupOverride(moveId, animationId)` (clip time). Skip for a BORROWED clip
  (`AttackAnimations.Resolve` returns a second value `borrowedFrom`) — borrowed clips are retimed to the
  move, not the reverse.
- `ws = move.WeaponSpeed or 1`, `tempo = move.Tempo or 1`, `playback = ws × tempo`,
  `spawn = move.SpawnDelaySeconds or 0`, `clipLen = AttackWindows.ClipLength(animationId)`.
- `StrikeSeconds = marker / playback + spawn` (this is where the hitbox opens in swing time).
- `ClipMatch.WindupSeconds = marker / ws` (AttackCatalog divides the authored windup by `tempo` and the
  marker by `ws × tempo`; equal when authored = marker/ws).
- `ClipMatch.RecoverySeconds = clipLen / ws − tempo × (StrikeSeconds + move.ActiveSeconds)`, clamped to
  `Limits.PhaseSeconds`. If it would be below `PhaseSeconds.Min`, still return it clamped AND add a note
  ("the clip ends before this move's hit window does").
- Spec both formulas: feed the matched numbers back through `AttackCatalog.Get` with the clip's length
  known and with it unknown (`AttackConstants.Windows.SyncToClipLength = false`) — the two timelines must
  agree within 1e-6. That test is the proof the button does what it says.

### 1.3 UI

- `Readout.lua`: new section **FRAME DATA** directly under EFFECTIVE TIMELINE, `StatRow`s:
  `Startup / Active / Recovery` as `"12f / 9f / 24f"`; `On hit` `"+3 to +12"`; `On block` `"−33 to −24"`
  with a Detail caption "No blockstun: the blocker acts at once."; `Hits to kill` `"10 (string: 8)"`;
  `Blocks to break guard` `"6 (staggered: 4)"`; `Clean hits to break guard`; `DPS`. Color on-hit/on-block
  values `Positive` when ≥ 0 else `Warning` — paired with the sign, never hue alone.
- `TimelineBar.lua`: a third marker, `Tokens.Color.TextPrimary`, at `StrikeSeconds`, plus row
  "Strike marker" (`"0.31s"` / `"none"`). Legend text updates to name all three markers.
- Timing tab: button **Match timing to clip** (legacy `Button`, disabled when `entry.ClipMatch == nil`)
  → `context.Edit(function(m) m.WindupSeconds = match.WindupSeconds; m.RecoverySeconds = match.RecoverySeconds end)`.
  It needs the entry: pass `SelectedEntry` into the tab context (add `Entry: Fusion.Computed<MoveEntry?>`
  to `Fields.FormContext`).
- Fix the two Copy hints (see §0).

**As built (2026-09-29) — where it differs from the text above, and why:**
- **"Never" is `nil`, not `math.huge`.** Every `…HitsTo…` count is `number?`; `nil` means never. A remote's
  handling of `inf` is not something to lean on for a value the UI branches on.
- **`ClipMatch` needs only the clip's LENGTH, not a marker.** With no marker the authored windup is already
  what the catalogue swings, so the match keeps it and fixes recovery alone. Requiring a marker would have
  disabled the button for nearly every clip in the game today (the boot log shows almost none carry `Hit`).
  Still nil for a borrowed clip, an unknown length, or a clip longer than `MaxSwingSeconds` (the catalogue
  refuses to sync to one).
- **`StrikeSeconds` is shown for a borrowed clip too** — the LENDER's marker at the catalogue's retimed
  playback speed, which is where that swing really connects. Only `ClipMatch` is withheld for it.
- **`AttackCatalogEntry` gained `BorrowedFrom: string?`** (set in `AttackCatalog.Get`) so the editor reads
  the borrowed state from the one resolution instead of re-running `AttackAnimations.Resolve` beside it.
- **No new note for "the clip ends before this move's hit window does".** The existing note (hitbox still
  open when the clip ends) fires on the same condition; a second one would say the same thing twice.
- **`CombatConstants.MaxHealth` is read by no runtime** — players keep the Humanoid default of 100, which it
  equals. It is still the right reference (it names the player pool); the header of `MoveBalance.lua` says so.
- The frame-data block is its own component, `Screens/DevTools/MoveEditor/FrameData.lua`, beside
  `TimelineBar.lua`, rather than more rows inlined into `Readout.lua`.

**Tests:** `Tests/MoveEditor/MoveBalance.spec.lua` — frames rounding; on-hit/on-block for a known timing;
hits-to-kill with Damage 0 (huge, not a crash) and exact divisors; guard math reads the live constants
(assert against `DefenseConstants.Guard.Max / (DrainPerPowerLevel × level)`, not a literal). ClipMatch
round-trip spec as in 1.2.

---

## Phase 2 — Undo / redo

### 2.1 `Shared/Authoring/DraftHistory.lua` (new, pure, specced)

```lua
export type History
function DraftHistory.new(capacity: number, coalesceSeconds: number): History
function DraftHistory:Record(moveId: string, before: MoveDefinition, now: number): ()  -- pushes `before`, clears redo
function DraftHistory:Undo(moveId: string, current: MoveDefinition): MoveDefinition?   -- pops undo, pushes current to redo
function DraftHistory:Redo(moveId: string, current: MoveDefinition): MoveDefinition?
function DraftHistory:CanUndo(moveId): boolean / :CanRedo(moveId): boolean
function DraftHistory:Clear(moveId: string): ()
```
- Stacks PER MoveId (switching moves must not undo across moves). Capacity 50 (`Constants.MoveEditor.UndoDepth`).
- **Coalescing:** a `Record` within `coalesceSeconds` (0.4, `Constants.MoveEditor.UndoCoalesceSeconds`) of
  the previous `Record` for the same move is DROPPED (the pre-drag state is already on the stack) — a
  stepper drag or a gizmo drag is one undo step.
- Store `MoveTypes.Clone` copies, never the live draft.

### 2.2 Wiring

- `MoveEditor/init.lua` `context.Edit`: `history:Record(current.MoveId, current, os.clock())` before
  setting the new draft. Skip when `current.MoveId == ""`.
- Two new handle signals are NOT needed: undo/redo are screen-local. Add `UndoRequested`/`RedoRequested`
  handlers inside `init.lua` (they set `draft` and fire `draftEdited` exactly like an edit, so the driver
  previews them). Expose `Undo: () -> ()`, `Redo: () -> ()`, `CanUndo/CanRedo: Computed<boolean>` on the
  handle for the driver's keys.
- Clear a move's history on Revert, ResetDefault, RestoreVersion (Phase 6) and Delete — the driver calls
  `handle.ClearHistory(moveId)` after those succeed. Save does NOT clear.
- Keys (driver, editor-scoped, modifier held): `Ctrl+Z` undo, `Ctrl+Y` and `Ctrl+Shift+Z` redo. Guard:
  not while a TextBox has focus (`UserInputService:GetFocusedTextBox()`), so text-field undo stays native.
- Readout ACTIONS: an Undo / Redo row (legacy buttons, `Disabled` from CanUndo/CanRedo).

**Tests:** `Tests/MoveEditor/DraftHistory.spec.lua` — push/undo/redo order, redo cleared on new record,
coalescing window, per-move isolation, capacity eviction, stored copies not aliased.

---

## Phase 3 — Test bench controls + hit log

All of these REUSE the Dev Menu's server remotes (`Constants.Debug.DevMenu.RemoteNames`) — no new server
code. Call them from `MoveEditorClient` exactly as `DevMenuClient` does.

| Control | Remote | Args → result |
|---|---|---|
| Spawn dummy (exists) | `SpawnDummy` | () → `DevMenuSpawnDummyResult` |
| Dummy guard toggle | `SetDummyGuard` | (boolean) → `DevMenuDebugDummyStateResult { GuardEnabled, ActiveCount }` |
| Read dummy state on open | `GetDebugDummyState` | () → same |
| Spawn bot | `SpawnTrainingBot` | (style, difficulty, weapon?) → `DevMenuSpawnBotResult` |
| Clear all | `DespawnAllDebugDummies` then `DespawnTrainingBots` | () → action results |

- Bot styles/difficulties: `TrainingBotConstants.Styles` keys (FullFight, Aggressor, Turtle, AttackOnly,
  BlockOnly, **ParryOnly**, DodgeOnly) and `.Difficulties` (Novice, Adept, Master); defaults
  `DefaultStyle`/`DefaultDifficulty`. **The dummy cannot parry** (guard only — `DebugDummySystem.SetGuard`);
  "test against a parry" = spawn a ParryOnly bot. Say that in the bench's caption.
- Order dropdown options from the constants' own tables, sorted — never a hardcoded list.
- Handle additions: `DummyGuard: Value<boolean>`, `BotStyle: Value<string>`, `BotDifficulty: Value<string>`,
  signals `DummyGuardToggled(boolean)`, `SpawnBotRequested()`, `ClearBenchRequested()`.

### Hit log

- Handle: `HitLog: Value<{ HitLogEntry }>`, signal `ClearHitLogRequested`.
```lua
export type HitLogEntry = { -- in MoveEditor/Types.lua
	MoveId: string, Kind: string, Damage: number, GuardDrain: number,
	ComboStage: number, SinceSwing: number, Target: string,
}
```
- Driver: subscribe `AttackInputClient.OnAttackStarted(payload)` — when `payload.MoveId` is the move last
  TESTED (Phase-1 `lastTest`), record `swingStartedAt = os.clock()`. On `Combat_Feedback` with
  `Role == "Attacker"` and that MoveId, prepend an entry (`SinceSwing = os.clock() − swingStartedAt`,
  `Target = feedback.Defender.Name`, `ComboStage = feedback.ComboStage`). Cap 20.
- Readout section **HIT LOG** (after TEST BENCH): one row per entry, mono numerals, `Kind` as a
  `StatusTag` (Clean/Backstab → Positive, Blocked/GuardBroken → Warning, Parried/Evaded/Trade →
  TextDisabled). A Clear button. Rows via `scope:ForPairs` (see Browser.lua header).
- The footer "Landed:" line stays.

**Tests:** none headless (remote/UI); playtest checklist in §9.

---

## Phase 4 — Hitbox on your character, and placing it by hand

### 4.1 Extract anchor resolution: `Shared/HitboxEngine/HitboxAnchor.lua` (new)

Move `HitboxEngine.resolveAttachmentPart`'s body (`Server/Combat/HitboxEngine/HitboxEngine.lua`, the
Root / RightHand→"Right Arm" / LeftHand→"Left Arm" / Weapon→Tool Blade→Handle→hand fallback chain) into
`HitboxAnchor.Resolve(model: Model, rootPart: BasePart, attachment: AttachmentPoint): BasePart` and have
the engine call it. One implementation, so the preview anchors exactly where the engine does.
Spec the fallback chain on a hand-built R6 model (+ one with a Tool/Blade).

### 4.2 `Client/DevTools/MoveEditor/HitboxWorldPreview.lua` (new)

- `HitboxWorldPreview.Start(handle)`: owns a `Folder` under `workspace.CurrentCamera` (client-only, never
  replicates) and a `Trove`. Rebuilds its parts when `Draft`'s Shape/Dimensions change; repositions every
  `RunService.RenderStepped` to `anchor.CFrame * draft.Offset` (anchor via `HitboxAnchor.Resolve` on the
  local character; `PlayerLifecycle.BindLocalCharacter` for character swaps).
- Visible when `IsOpen or PlacementMode` AND a draft exists AND `ShowOnCharacter` (new handle Value,
  default true, toggle in the readout).
- Part rules: `Anchored, CanCollide/CanQuery/CanTouch = false, CastShadow = false, Locked = true`,
  `Transparency 0.55`, `Color = Tokens.Color.Danger`, `Material = SmoothPlastic`. Local frame is
  HitboxTypes' (forward −Z). Per shape:
  - Box: one `Block` part, `Size = (W, H, L)`. **Weapon-anchored Box**: size = the resolved blade's `Size ×
    (SizeMultiplier or 1)` — mirror `SizeFromAttachmentPart`, and tint `AccentSecondary` to say "the blade
    decides this".
  - Sphere: `Ball`, diameter 2R.
  - Cylinder: `Cylinder` part (Roblox cylinders lie along X) rotated `CFrame.Angles(0, math.rad(90), 0)`,
    `Size = (L, 2R, 2R)`, centred.
  - Capsule: the cylinder + two `Ball`s at ±L/2.
  - Beam: the cylinder, offset forward by L/2 (reach shape — grows from the origin).
  - Cone: 8 stacked cylinder slices from the apex forward, slice i radius = `tan(angle/2) × (i+0.5)·L/8`.
  - Arc: 16 `Block` segments around the sector (inner→outer radius, height H), yaw-spread over AngleDegrees.
  Keep all of this in one `build(shape, dims) -> { BasePart }` + one `place(cframe)`; spec `build` for
  part counts/sizes (no Workspace needed).

### 4.3 Place mode (direct placement)

- Handle: `PlacementMode: Value<boolean>`, `PlacementTool: Value<"Move" | "Rotate" | "Resize">`,
  `PlacementSnap: Value<number>` (studs: 0 / 0.25 / 0.5 / 1; rotation snaps 15°).
- `ScreenFrame.Mount`'s `IsOpen` becomes `isOpen and not placementMode`. The editor session stays open
  (character stays frozen — do NOT fire `SetEditorOpen(false)`). Closing the modal also clears
  `UiModalOpen` (ModalScreen) — intended: the camera and mouse are free to orbit.
- A compact non-modal bar (new `Screens/DevTools/MoveEditor/PlacementBar.lua`, its own ScreenGui, bottom
  centre, `Panel` + `Stack.Row`): tool segment (Move / Rotate / Resize), snap segment, a live readout
  (`X 0.00 Y 0.50 Z −3.00 · yaw 0°`), **Done**. `KeyLegend` for its keys: `1/2/3` tools, `Enter`/`Esc` done.
  Push an Escape entry: `chrome:BindEscape("MoveEditorPlacement", handle.PlacementMode, exit)` so Escape
  leaves placement before it closes the editor.
- Gizmo (`HitboxWorldPreview`, created only in placement): `Handles` (Style Movement or Resize) or
  `ArcHandles`, `Adornee` = the preview's primary part, parented to `PlayerGui`.
  - Move: `MouseDrag(face, distance)` → `offset.Position + offset.Rotation:VectorToWorldSpace(Vector3.FromNormalId(face)) * snap(distance)`
    relative to the drag's START offset (capture on `MouseButton1Down`), then
    `MoveTypes.ComposeOffset(newPos, rotation)`.
  - Resize: face axis → dimension (X→Width, Y→Height, Z→Length; round shapes: X/Y→Radius, Z→Length),
    one-sided like Studio: dimension += d, centre moves d/2 along the face normal. Clamp to
    `Limits.Dimensions`.
  - Rotate: `ArcHandles.MouseDrag(axis, relativeAngle)` → compose the start rotation with the drag, then
    read back degrees with `CFrame:ToEulerAnglesYXZ()` → `OffsetRotation = (pitch, yaw, roll)` (matches
    `ComposeOffset`'s YXZ order), clamp to `Limits.RotationDegrees`.
  - Every drag step goes through `context.Edit` → debounced Preview (live) → undo coalesces the drag.
- Readout ACTIONS: **Place in world** (enters placement) and the **Show on character** toggle.
- Placement is available in any server for an admin (it only edits the draft); Studio-only is Phase 7.

**Tests:** HitboxAnchor spec; preview `build` spec. Placement is playtest-only (§9).

---

## Phase 5 — Bulk edit a group

### 5.1 Server

- `DefaultMoveRegistry.StageOf(moveId): StageCategory?` (new; the descriptor already has `Stage`).
- Remote **`MoveEditor_BulkScale`** (add as `BulkScale`):
```lua
-- request
{ Group: string, Stage: string?, Scale: { WindupSeconds: number?, ActiveSeconds: number?,
  RecoverySeconds: number?, Cooldown: number?, Damage: number?, PostureDamage: number? }, Save: boolean }
-- result: { Success, Reason?, Entries: { MoveEntry }? }
```
- Pure core, exported for spec: `MoveEditorSystem.ScaleMove(move, scale): MoveTypes.MoveWire` — multiply
  each present field; multipliers clamped to `Constants.MoveEditor.BulkScaleLimits = { Min = 0.25, Max = 4 }`;
  result then goes through the normal `applyDraft` (so it clamps and validates like any edit).
- Target set: every entry whose `groupOf(move, source) == Group` and (when `Stage` given) whose
  `DefaultMoveRegistry.StageOf` matches. Custom groups ignore `Stage`. Reject an empty target set
  (`NoMovesMatched`).
- Scales CURRENT live values (cumulative), not built ones — say so in the UI.
- `Save = true` → persist each through the Save path (share one local `persist(move, source, admin)`
  helper with `handleSave`; do not copy it). Also writes history (Phase 6).
- Rate limit: one call counts once; cap targets at 64 per call.

### 5.2 UI — a fifth form tab, **Tools**

Tabs become `Hitbox · Timing · Impact · Identity · Tools`. Tools holds group-level and persistence tools
(this phase's Bulk, Phase 6's History, Phase 7's Source), which are not properties of one move's inputs.
- **BULK** section: "Group: <selected move's group>" fact, Stage choice (All + the stages present in that
  group, Default groups only), six `NumericField`s in PERCENT (−75…+300, step 1/5, default 0 = unchanged;
  convert to multiplier `1 + p/100`), **Apply (live)** and **Apply & Save**, both through a two-press arm
  (`armedButton` in Readout.lua — lift it into `Fields.lua` as `Fields.ArmedButton` when this second
  caller appears). Status line reports `"Scaled 12 moves."`.
- Driver: on success `upsertEntry` each returned entry; if the open move is among them, `openMove` it.

**Tests:** `ScaleMove` spec (only present fields change, multipliers clamp, output validates).

---

## Phase 6 — Version history

### 6.1 Storage

- Key `"MoveHistory_" .. moveId` in the same DataStore (`StorageConfig.CustomMoveDataStoreName`).
- Value: `{ Versions: { { Version: number, SavedAt: number, AdminName: string, AdminUserId: number,
  Record: Record } } }`, newest LAST, capped at `Constants.MoveEditor.HistoryDepth = 10`.
- Written with **UpdateAsync** (atomic append + trim) inside `withRetry`, on every successful Save (single
  and bulk), AFTER the record write succeeds. A history-write failure logs an error and does NOT fail the
  save. `Record` is `MoveRecordCodec.Encode` / `EncodeOverride` output — the same bytes the save wrote.
- Pure helper for spec: `MoveEditorSystem.AppendVersion(doc: unknown, entry, depth): Doc` — tolerates a
  missing/corrupt doc, assigns `Version = last + 1`, trims oldest.

### 6.2 Remotes

- **`History`** `(moveId) → { Success, Reason?, Versions: { { Version, SavedAt, AdminName, Summary: string } }? }`
  — `Summary` is server-computed: the authored fields that differ from the PREVIOUS version, e.g.
  `"WindupSeconds 0.30→0.26, Damage 10→12"` (compare decoded+validated moves field by field over
  `MoveTypes.ToWire` keys; cap at 4 fields then "+N more").
- **`RestoreVersion`** `(moveId, version) → EntryResult` — decode (`MoveRecordCodec.Decode` /
  `DecodeOverride` with the built move), then apply as a **Preview** (live, NOT saved): the admin reviews
  and Saves. Custom: re-stamp identity via `stampCustom`. Default: `ApplyEdit`.
- Deleting a custom move also removes its history key.

### 6.3 UI (Tools tab, **HISTORY** section)

- "Load history" button (history is fetched on demand, not on every selection). Rows (ForPairs): `v7 ·
  2026-09-29 14:02 · Gdani` + the summary line + **Restore** (two-press). After restore: status
  `"Restored v7 — live, not saved."`; the driver clears the move's undo history.

**Tests:** `AppendVersion` spec (append, trim, corrupt input, version numbering); `Summary` diff spec.

---

## Phase 7 — Studio only: write moves into the game's source

**Why this shape:** a running Roblox server cannot write to the project, and play-mode edits are thrown
away on Stop. So: the Studio server generates a Lua module and POSTs it to a local helper, which writes it
into `src/`; Rojo syncs it into the edit DataModel; it ships with the build and lives in git. The
DataStore stays the live-server authoring path.

### 7.1 The generated files

- Folder: `src/ServerScriptService/Server/Combat/AuthoredMoves/` with subfolders `Moves/` (custom moves)
  and `Overrides/` (Default-move overrides). It lives under `Server/Combat`, already mapped in
  `default.project.json`, `live.project.json` and `test.project.json` — no project changes. Create the
  folders with one committed `README.md` each so git keeps them (Rojo ignores `.md`).
- File name: MoveId with every non-`[%w%-]` character replaced by `_` (`default:Sword:Basic:1` →
  `default_Sword_Basic_1.lua`); the real id is inside the file.
- File content: a ModuleScript returning the record table:
```lua
--!strict
-- GENERATED by the Move Editor (Studio: Tools → Source). Schema v3 -- see MoveTypes.lua.
-- Safe to hand-edit; re-writing from the editor replaces this file.
return {
	SchemaVersion = 3,
	MoveId = "rising-palm-4821",
	...
}
```
- Generator: `Server/Systems/Support/MoveSourceWriter.lua` (pure): `ToLua(record: Record): string` —
  sorted keys, tabs, trailing commas, numbers `%.6g` (integers without a decimal), strings escaped with
  `string.format("%q", s)`, nested tables recursively, arrays in index order. Must be deterministic
  (same record → byte-identical text) so re-writing an unchanged move produces no git diff.

### 7.2 Loading them: `Server/Combat/AuthoredMoveLibrary.lua` (new)

- `AuthoredMoveLibrary.Load(): ()` — `require` every ModuleScript under `AuthoredMoves/Moves` → `MoveRecordCodec.Decode`
  → `MoveRegistryManager.Validate` → `Upsert`; every one under `Overrides` → `DefaultMoveRegistry.SetShipped(id, candidate)`.
  Pcall each require; a broken file is logged and skipped, never fatal. Records `IsShipped(moveId)`.
- Called from **`Main.server.lua` immediately after `MoveRegistryManager.Init()`** (and after
  `WeaponRoster.Start`), BEFORE the combat Inits and before `MoveEditorSystem.Init` — shipped content is
  gameplay content, it must not depend on an admin System booting. Add the step to Main's numbered boot
  comments.
- **Precedence:** built constants → shipped override (source) → DataStore override; shipped custom move →
  DataStore record with the same id wins (it is the newer live edit). `DefaultMoveRegistry`:
  - new `SetShipped(moveId, candidate)` (validated like ApplyEdit, stored in a `shipped` table);
  - `project(descriptor)` applies the shipped override first, so **`GetBuilt` returns built + shipped** —
    "Reset to default" now means "back to what ships", which is the honest meaning;
  - `ResetCache` clears `shipped` too.

### 7.3 The local helper: `scripts/move-writer.py` (new, stdlib only)

- `python scripts/move-writer.py` → `http.server` bound to **127.0.0.1:34880** only
  (`Constants.MoveEditor.SourceWriter = { Url = "http://localhost:34880", TimeoutSeconds = 5 }`).
- `GET /health` → `{"ok": true, "root": "<abs src path>"}`.
- `POST /write` `{ "kind": "move" | "override", "id": str, "source": str }` → writes
  `AuthoredMoves/{Moves|Overrides}/<sanitised>.lua`; runs `stylua <file>` if `stylua` is on PATH; returns
  `{"ok": true, "path": "<repo-relative>"}`.
- `POST /delete` `{ "kind", "id" }` → removes the file if present.
- Hard rules: resolve the target path and refuse anything outside the AuthoredMoves folder (path
  traversal); `id` must match `^[\w:\-]{1,64}$`; body ≤ 256 KB; UTF-8 only; log each write to stdout.

### 7.4 Server remotes (Studio-only, created in every build)

- **`WriteToSource`** `(moveId) → { Success, Reason?, Path: string? }` — refuses `NotStudio` unless
  `RunService:IsStudio()`. Takes the LIVE move (so flush the Preview first client-side), `ToLua` of
  `MoveRecordCodec.Encode` (custom) / `EncodeOverride` (Default), `HttpService:RequestAsync` POST.
  Failures map to codes: `HttpDisabled` (HttpService.HttpEnabled false — "Game Settings → Security → Allow
  HTTP Requests"), `WriterUnreachable` ("run `python scripts/move-writer.py`"), `WriterRefused`.
  On success: **delete the DataStore copy** (custom: record + index entry; Default: override key) so the
  source file is the single truth, and mark the entry shipped. Log admin + path.
- **`RemoveFromSource`** `(moveId)` → POST /delete; the move stays live this session; after a restart it is
  gone (custom) / back to built (Default). Two-press in UI.
- **`ExportSource`** `(moveId) → { Success, Source: string? }` — returns the generated text, Studio only.
  This is the fallback when Phase 0a says localhost is blocked.
- Entry gains `Shipped: boolean` (source file exists for it) — shown as a chip `IN SOURCE`.

### 7.5 UI (Tools tab, **SOURCE** section, rendered only when `RunService:IsStudio()` on the client)

- Caption: "Writes this move into src/ as a Lua file Rojo syncs in. It ships with the build and lives in
  git; its DataStore copy is removed."
- Buttons: **Write to source**, **Export** (opens a read-only multiline `TextBox` with the Lua, text
  selectable, `ClearTextOnFocus = false`), **Remove from source** (two-press). Status shows the written path.
- Driver: flush pending Preview → invoke → on success upsert entry.

**Tests:** `MoveSourceWriter.spec` — determinism (same record twice → identical strings), escaping (quotes,
newlines, `]]`), integer vs float formatting, nested ordering. `AuthoredMoveLibrary.spec` — build
`ModuleScript`s in the test place (run-in-roblox runs with plugin security, so setting `.Source` should be
allowed — confirm, else construct via a fixture folder of real files under
`src/Tests/Fixtures/AuthoredMoves/` mapped by test.project.json); assert a shipped custom move lands in
the registry, a shipped override changes `GetBuilt`, a DataStore override still overlays it, a broken
module is skipped. A pytest-free smoke for the Python helper: `python scripts/move-writer.py --self-test`
(writes to a temp dir, checks traversal refusal).

---

## 8. Docs & memory to update when done

- `docs/design/move-editor-guide.md`: every new control, the Tools tab, Place mode keys, the source-write
  workflow (start the helper, allow HTTP in Studio), and the precedence chain.
- `docs/ui-ux-philosophy.md` Build Status Move Editor bullet: Tools tab + Place mode bar.
- `CLAUDE.md` "Two build configs": the AuthoredMoves folder ships in both configs; the helper is dev-only;
  `MoveEditorSystem` is still required (DataStore content), and `AuthoredMoveLibrary` now loads shipped
  content from Main.
- Memory: update `move-editor-rebuild-2026-09-29.md` (or a new dated one) with the Phase 0 results.

## 9. Playtest checklist (after the suite passes)

1. Open editor → a Basic stage: frame data present; on-hit/on-block signs match the timeline by eye.
2. A move with a marked clip: violet clip end + white strike marker; Match timing → UNSAVED; effective
   timeline unchanged.
3. Drag a number 20 steps, Ctrl+Z once → back to the pre-drag value; Ctrl+Y restores.
4. Show on character: volume sits where the plots say; switch to RightHand anchor → follows the arm.
5. Place → Move handle drag, Rotate, Resize; Escape leaves placement (not the editor); Test hits where you
   placed it (confirm with Show live hitbox volumes).
6. Dummy guard on → Test → hit log says Blocked; ParryOnly bot → Parried; clear all.
7. Bulk: Sword / Basic / +10% windup Apply → all Sword Basics UNSAVED; Apply & Save → saved, history has a
   version each.
8. History: Load → summaries read right; Restore v(n−1) → live, unsaved; Save.
9. Studio: Write to source → file appears in `src/.../AuthoredMoves/`, Rojo syncs, DataStore copy gone;
   stop, play again → move still there from source. Export shows the same text. Remove from source.
10. Published / live-config server: Tools → SOURCE section absent; the three Studio remotes refuse `NotStudio`.

## 10. Suggested order and size

Phase 0 (spikes) → 1 → 2 → 3 → 4 → 5 → 6 → 7. Each phase is independently shippable and ends with the
gates in §0. Rough size: P1 ~450 lines, P2 ~200, P3 ~250, P4 ~650, P5 ~300, P6 ~350, P7 ~650 + the Python
helper ~150, plus specs.

## 11. As built (2026-09-29) — departures from the text above, and why

Phase 1's are listed under 1.3. The rest:

**Phase 2 — undo/redo**
- Coalescing is a **sliding** window: every `Record` inside `UndoCoalesceSeconds` of the previous one is
  dropped AND moves the window, so a drag of any length is one step. `Undo`/`Redo` close the window, so the
  first edit after either always records.
- Undo/Redo also clear on a restored version, a bulk scale that touched the open move, and Write/Remove
  from source only insofar as those replace the draft (restore and bulk do; source writes do not change
  values). Undo / Redo buttons are a row in ACTIONS; the readout's `LayoutOrder`s went sparse (×10) so
  later sections slot in without renumbering.

**Phase 3 — bench + hit log**
- `TrainingBotConstants` already had `StyleOrder`/`DifficultyOrder` (presentation order, **eight** styles —
  `ParryTrade` too). The dropdowns use those rather than sorting the keys.
- The bench and the log are their own components (`TestBench.lua`, `HitLog.lua`). The log clears when the
  selection changes (it is "this move's tests"). Bench refusal codes (`InvalidPreset`, `InvalidWeapon`,
  `InvalidRequest`) are in `Copy.FAILURES`.
- Observed in the Phase 0 playtest log, not fixed here: `DevMenuClient` hits its own rate limit at boot
  (`GetDebugDummyState` / `ListPlayers` / `ListFlightTuning` / `ListBugReports` "RateLimited"). The editor's
  one extra `GetDebugDummyState` on open shares that bucket; a refusal just leaves the toggle's last value.

**Phase 4 — in-world hitbox + Place mode**
- The pure parts are two modules, both specced (`Tests/MoveEditor/PlacementPreview.spec.lua`):
  `Client/DevTools/MoveEditor/HitboxPreviewShapes.lua` (shape → part *pieces*, data only) and
  `PlacementMath.lua` (move / one-sided resize / rotate / snap / the 2π `UnwrapDelta`).
- Gizmo adornees: an invisible part the size of the volume's **bounding box** (`HitboxGeometry.BoundingBox`)
  for Move/Resize, and a small part at the volume's **origin** for Rotate — `ComposeOffset` rotates about the
  origin, so the rings sit there.
- **1/2/3 are also hotbar keys.** Place mode binds 1/2/3/Enter through `ContextActionService` at
  `High + 100` and sinks them, so they never reach the hotbar while placing; unbound on exit.
- Resize rules the plan left open: a Sphere's or Arc's radius grows around its fixed origin (the dragged
  face tracks the radius 1:1, no shift); Cylinder/Capsule/Beam radius is one-sided (radius += d/2, centre
  shifts d/2); a reach shape's (Beam/Cone) Back face moves the origin, its Front face moves the tip; a
  Cone's X/Y do nothing (its width is its angle); a weapon-anchored Box is not resizable (the blade sizes it).
- **Place mode owns the camera** (owner playtest, 2026-09-29: "the camera doesn't move"). Freeing the mouse
  every frame, as first built, froze the view -- the stock camera only orbits while it holds the mouse
  locked during a right-drag, and the frozen character cannot walk it anywhere. `PlacementCamera.lua` now
  sets `Scriptable` and orbits a focus point (right-drag orbit, middle-drag / WASD-QE pan, wheel zoom, F
  re-centre), locking the mouse only while dragging the view. The focus does NOT follow the volume per
  frame: Handles measure the mouse against the axis as seen from the camera, so a following camera would
  feed back into the drag. ShiftLockCamera is suspended through `SetInputSuspended`, which is now KEYED BY
  OWNER (the emote wheel was its only caller; a single boolean would let one release the other's hold).
- **Place in world / Show on my character live in the Hitbox tab** (end of PLACEMENT), not the readout's
  ACTIONS as 4.3 says -- owner's call after the first look: they are a way of typing the offset and
  rotation fields they sit beside.
- The handle gained `EditDraft` (the screen's own `context.Edit`), `ShowOnCharacter`, `PlacementMode`,
  `PlacementTool`, `PlacementSnap` (default 0.25 studs).

**Phase 5 — bulk edit**
- `MoveEntry.Stage` was added (Default weapon moves) — the client needs it to offer the stages present in
  a group. The stage picker is a row of buttons, not a Dropdown: `Dropdown`'s options are fixed at mount
  and a group's stages change with the selection.
- A move that fails to apply or save is skipped and counted; the result carries every move that DID change
  plus the first reason one did not (`Scaled 11 moves, but not all: …`). Refusals: `NoMovesMatched`,
  `TooManyMoves` (> `BulkScaleMaxMoves` = 64), `InvalidRequest` (malformed, or every factor is 1).
- The percentages reset to 0 after each apply, so a second press is a decision (the scale compounds).
- `persist(player, move, source)` is the one write path for Save and bulk Save (and appends history).

**Phase 6 — history**
- Listed **newest first**; each summary is against the version before it. The arrow is ASCII `->`.
- A Save (or bulk Save touching the open move) drops a loaded history list rather than silently showing
  one without the newest version; "Reload history" fetches it again.
- Restore decodes through `MoveRecordCodec.Decode` / `DecodeOverride` and goes through `applyDraft` — i.e. it
  is exactly a Preview. Refusals: `InvalidVersion`, `VersionNotFound`.

**Phase 7 — source**
- `Constants.MoveEditor.SourceWriter` is `{ Url }` only: `HttpService:RequestAsync` takes no timeout, so a
  `TimeoutSeconds` would be a field no runtime reads.
- `MoveSourceWriter` escapes strings **by hand**, not with `%q` — `%q` writes a newline as backslash +
  a real line break, splitting one value across lines in the file and in every diff.
- `AuthoredMoveLibrary.spec` uses real fixture files (`src/Tests/Fixtures/AuthoredMoves/`), through a
  `LoadFrom(root)` seam, rather than writing `ModuleScript.Source` at runtime — no dependence on the
  harness's security level.
- `DefaultMoveRegistry` gained the shipped layer (`SetShipped`, `IsShipped`), and `ApplyEdit`/`SetShipped`
  share one `validateOverride`.
- A shipped custom move with no DataStore record reads as SAVED (its file is its saved state):
  `savedMove` falls back to `AuthoredMoveLibrary.GetShippedMove`, and Revert follows it.
- **Delete refuses `InSource`** for a custom move that ships in source — deleting only the live copy would
  bring it back from its file at the next boot. Remove it from source first.
- Remove from source keeps the move live this session: a custom move reads NEVER SAVED, a Default move
  becomes an ordinary unsaved live override (it is back to its weapon's values after a restart).
- The IN SOURCE chip is in the readout's title row (bronze), not in the browser rail.
