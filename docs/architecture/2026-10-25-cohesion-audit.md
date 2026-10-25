# Cohesion audit: does the tree work as one system? (2026-10-25)

Scope: all of `src/` (about 770 files) plus `scripts/` and the three `*.project.json`. The pass measured twelve axes,
fixed the four where the score proved incoherence, and left the rest. Nothing here restates an open item from
`2026-10-25-codebase-audit.md` or `2026-10-25-deepwoken-combat-pass.md` without re-checking it.

**Evidence level.** Everything below was read from source or measured by running `selene`, the scripts and the TestEZ
suite on this machine. Nothing was playtested. "Inferred from source" marks a conclusion reached by reading, not running.

Where CLAUDE.md and the pass prompt disagreed, CLAUDE.md won. The one place it mattered: CLAUDE.md says the suite takes
5-10 minutes; here a full run is about 90 seconds, so the prompt's "run it in the background" was kept but the wait was short.

## 1. Baseline

| Measure | Result |
|---|---|
| `selene src/` | 0 errors, 2 warnings (the known `UDim2.fromScale` pair, `UI/Screens/Inventory/init.lua:521,528`), 0 parse errors |
| Working-tree suite, before any edit | **3494 passed / 43 failed**, matching 2026-10-25 exactly |
| HEAD suite | 3458 / 43, from the prompt; not re-run |
| Working-tree suite, after this pass | **3538 passed / 7 failed** |
| Dirty paths at the start | 54; 59 now (this pass adds 5: 2 new source files, 1 new spec, 2 new scripts; the other edits are in files that were already dirty) |

Two environment findings. A `run-in-roblox` started by another session (the `hopeful-agnesi` worktree) had been hung for 16 minutes
holding port 50312 with no Studio process; it was stopped with the user's approval, and the baseline ran straight after.
And `scripts/run-tests.lua`'s printed tree is **truncated after the `Combat` group**, so a failure outside `Combat` is invisible in it. The
complete list is the `TestService: ...` blocks (each ends with the failing spec line); the 43 were recovered from those.

## 2. The twelve axes

Scores are the state when measured. "→" is the score after this pass's fix.

| # | Axis | Score | Evidence |
|---|---|---|---|
| A1 | Single source of truth | 8 | Every attribute name goes through `AttributeConstants`; the only literal is a module-private one, `ImpactSparks.lua:82` (`"DefaultTexture"`). Remote names live in one `RemoteNames` table per System. One tunable has two sources with the same value: `SwingFadeSeconds` at `FXConstants.lua:640` and `AttackConstants.lua:644`. |
| A2 | One writer per state | 6 → 9 | `RootControlLocked` has one writer (`RootControl.lua:58`) except `AirComboSystem.lua:295`, a stale re-assert from before claims existed (removed). `KnockbackUntil` had four bare writers (`DamageSystem.lua:291`, `DomainSystem.lua:223,417`, `AdminActionSystem.lua:481`) against a header naming one. |
| A3 | Declared contracts | 9 | `CombatTick.Register` asserts an unknown phase (`CombatTick.lua:111`) and every combat System registers; `BootManifest.AssertBootComplete` covers remotes; attribute literals are absent (A1). |
| A4 | Docs are true | 6 | `AttributeConstants.lua:51-72` named deleted writers (`DevMenuSystem.SetTarget*`, `CombatSystem.SetPlayerInvisible`, `CombatSystem`'s notifier). `RateLimiter.lua:8` named `CombatSystem.lua`. `parry-block-system-plan.md:3` said "not built". `CombatSystem`, deleted, is still cited **162 times** in comments (`Types.lua` 24, `CombatConstants.lua` 22, `AdminActionSystem.lua` 14, `RespawnSystem.lua` 10). |
| A5 | No dead weight | 9 | One module has no non-spec inbound require: `UI/Components/HoverLabel.lua` (already known). The three dead parkour states and `ActionIcon` are gone (A1 of the codebase audit holds). |
| A6 | Duplication that can drift | 6 | Identical bodies: `clearInheritedInstances` in `BlimpSystem.lua`/`BoatSystem.lua` (known); `resolveJoints` in `GuardStrainPose.lua`/`HitFlinchPose.lua`; `matchesKeybind` in `Chord.lua` vs `keybindMatchesInput` in `KeybindManager.lua`; a 60-line `numberRow` in `ControllerTab.lua`/`GameplayTab.lua`. |
| A7 | Observability | 6 → 8 | 44 of 50 `RateLimiter:IsLimited` call sites just `return` (e.g. `SettingsSystem.lua:163`), so a flooding client or a lost burst left no trace. Attack presses are answered (`OnPressRefused`), so the combat path was fine. |
| A8 | Test topology | 3 → 8 | 43 red tests made the suite useless as a gate; 36 were fixed (§3). |
| A9 | Failure isolation | 6 | Client `boot` isolates each `Start` (`Main.client.lua:100`; audit item A3 **holds**). Server `boot` is **bare**: `Main.server.lua:115-118` calls `system.Init()` unprotected, so one throw aborts every later System and the closing `AssertBootComplete`. `UI.Mount` (`UI/init.lua:197`) is bare by design and builds ~20 tiles in one function. |
| A10 | One impact vocabulary | 8 | `CombatFeedbackClient.lua:155,158,188,285` is the one place that turns `Perfect`/`GuardCracking`/`StringEnd`/`AirCombo` into a cue; the FX modules receive its result. `HitPrediction.lua:57,193` mirrors `StringEnd` for the predicted hit, deliberately. |
| A11 | Naming symmetry | 7 | Evade is the settled word on the wire and in constants, but the evade's camera kick is `FXConstants.CameraShake.Roll` (`MovementVFX.lua:207`) and its ghost module is `RollAfterimage`. "Dodge" appears only in comments. Guard/posture and hitstun/stun are used consistently by layer. |
| A12 | Config symmetry | 9 | `test.project.json` maps every folder under `Server/` and `Client/` (checked by script); `check-live-project.py` passes; `live` differs only by `globIgnorePaths`. |

## 3. What changed

| Axis | Defect | Fix | Commit |
|---|---|---|---|
| A8 | 13 cases pasted the baseline swing clip id | `AttackAnimations.spec`, `AttackCatalog.spec`, `WeaponSwingHitbox.spec` resolve it from `AttackAnimations.Get` | `8509ffa` |
| A8 | Specs called `Wedge` and `Projectile` retired; the preview-count table lacked 8 shapes | Registry specs use a name outside `HitboxTypes.ShapeOrder` (guarded); counts only pinned where known | `7df8cfd` |
| A8 | `ProgressionSpine` stand-in had no `SetAttribute`; the Inventory placeholder is hidden, not absent | Stand-in carries an Attribute surface; the spec checks visibility | `54bf5e8` |
| A8 | `EvadingState` "no press" case hit the combat-only gate first; `SurfaceLock` compared a float32 to a double | Set `InCombat`; compare with a tolerance | `a0434d6` |
| A8 | `Validate(ToWire())` round trips lacked identity; record fixture lacked `LocksWindup`; a Strike naming its own move is stored blank, not rejected | Stamp identity, add the field, test the self-reference with `Volley` | `e9fc9f7` |
| A8 | `WeaponInventorySystem` characters were unregistered combatants (`RequestWeapon` refuses them); `Grab` looked for `RootJoint` under the wrong part; `Projectile` lost its listener across `HitboxEngine.Reset`; an air swing with a 10 s windup is "late"; a backdate case needed the real clock to pass | Register combatants; search the rig; re-subscribe; in-time swing; `task.wait(0.06)` | `437ef98` |
| A8 | `GuiButton.Activated` cannot be fired by a script | Dropped the press, kept the marking check; **restore press no longer covered headlessly** | `2c39e53` |
| A8 | Evade-startup case asserted a design value that changed | Split into two cases that set the startup and restore it | uncommitted (file was already dirty) |
| A8 (real) | `FpsCounter` set `DisplayOrder = 10000`, which `ShellSurface.spec` forbids | `Layers.Debug` | `0bdf382` |
| A7 | Dropped calls left no trace | `RateLimiter` logs the first drop per player per window, with where the limiter was made | `a7738d5`, `f31d7c8` |
| A2 | `KnockbackUntil` overwritten by shorter stamps; `AirComboSystem` second writer of `RootControlLocked` | New `Server/Combat/MovementAllowance.lua` (extend-only), four call sites switched, `AirComboSystem` re-assert removed, `scripts/check-single-writers.py` | uncommitted (call sites are in files that were already dirty; the new files and the checker stay with them so HEAD is never half-converted) |
| A4 | Falsified headers | `AttributeConstants`, `RateLimiter`, `parry-block-system-plan` | `6b150c6`; `AttributeConstants` uncommitted (shares a file with A2) |
| Gates | Two rules had nothing enforcing them | `scripts/check-spec-literals.py`, `scripts/check-stale-refs.py` | `e143483`, `9b6201e` |

Final: **3538 passed / 7 failed** (+44 passed, −36 failed; the 44 are the 36 repaired cases plus 8 new ones: 6 for `MovementAllowance`, 1 for the limiter log, 1 from splitting the evade-startup case). The 7 are a subset of the original 43; no new failure appeared.

### The 43, classified

| Class | Count | Fixed |
|---|---|---|
| Fixture drift (pasted ids, re-learned shapes, stand-ins missing an API or not registered, identity-less round trips, stale clock/premise) | 34 | 34 |
| Real contract breach (`FpsCounter` literal) | 1 | 1 |
| Harness limit (`Activated` unfireable) | 1 | 1, with a coverage cut |
| Real gap, inferred from source: feint leaves the end-of-string lockout | 2 | 0 |
| Unresolved: `TrainingBotSystem` "lands its swings" family | 5 | 0 |

The feint cases: `SwingSequencer.Advance` sets `LockedUntil` for a one-stage Heavy (`SwingSequencer.lua`, `endsString`), and `CancelString` rewrites only
`ChainReadyAt`, so a feinted Heavy still owes the end-of-string cooldown and a fresh Heavy is refused `ChainDelay`. Whether a feint should refund it is a feel
decision (it touches the frozen skeleton), so it was not changed. The bot cases: in a debug run the bot threw 3 swings in 4 simulated seconds and none landed
(narration "Feint the Heavy (mix-up)"); whether that is seed-dependent tuning or a real gap in the bot's offence is not established.

## 4. Deferred axes

| Axis | Why |
|---|---|
| A1 | One duplicated 0.05 s fade. A harmless duplicate; fixing it is an edit in two Constants modules for no player-visible gain. |
| A3 | Scored 9; nothing proven incoherent. |
| A4 (the 162 references) | Rewriting 162 comments across about 30 files is its own change. `check-stale-refs.py` stops it growing. |
| A5 | `HoverLabel` is known and harmless. |
| A6 | Real, ranked below the four fixed. The keybind matcher pair is the one to do first (input matching drifting is a bug class here); the Blimp/Boat pair is audit item A2. |
| A9 | Whether a throwing System should halt the server or be skipped is a decision (see Escalations). |
| A10 | Scored 8; nothing proven incoherent. |
| A11 | A rename (`Roll` → `Evade` in FX names) is a pure rename and wants its own commit; no behaviour risk, no leverage. |
| A12 | Scored 9. |

## 5. Escalations

Each is a binary choice; none was decided here.

1. **Commit the 2026-10-25 work?** (Every fix that touched an already-dirty file is waiting on this.)
   - *Yes:* the audit fixes, the Deepwoken pass, the A2 `MovementAllowance` work, the evade-startup spec and the three doc correction lines enter history; HEAD gets 3538/7 and the new checker. Effort: review about 59 paths, then commit by concern.
   - *No:* nothing is lost on disk, but HEAD stays at 3458/43 and any of the dirty files is one stray checkout from loss.
   - Unblocks: committing A2 whole, and the dated-doc corrections.
2. **Faction assignment** (`profile.faction` is never written; 3 of 4 art trees are sealed).
   - *Derive from race at Finalize / choose at onboarding / earn it:* one of these is picked and `FactionManager` becomes the one writer. Effort: design plus a small System.
   - *Leave it unassigned:* only Foundation Forms exist for everyone, and the faction trees should leave the catalogue rather than show dead rows.
   - Unblocks: Qi Conflict, territory, Absorb.
3. **Turn on `CombatPowerConstants.Enabled`.**
   - *On:* a tier gap scales damage (never stun), so tiers 2-9 stop being badges. Needs balance numbers, marked REQUIRES PLAYTEST. Effort: tuning plus a fight test.
   - *Off:* combat is tier-blind; nothing to tune.
   - Unblocks: the "tier-up changes how you fight" pillar (D2).
4. **Held-hit body gate** (Deepwoken pass §7.1).
   - *Add a provisional hold deadline the attack gate reads:* a defender can no longer start a swing a held hit then eats. It changes how the rewind hold meets the attack layer, so it is a seam change. Effort: medium plus 150-200 ms playtest.
   - *Leave it:* "my M1 came out and got eaten" stays possible on laggy flank/rear hits.
   - Unblocks: raising the responsiveness and combo-flow scores.
5. **Blockcounter** (`DefenseStateMachine.lua:317` refuses a re-press while guarding).
   - *Allow the re-press:* a Deepwoken-style blockcounter becomes possible; it needs a telegraphed cost per `combat-philosophy.md`. Effort: small code, real design.
   - *Keep it:* the guard stays a held state; the stun parry remains the only answer to a string.
   - Unblocks: nothing else depends on it.
6. **Anything touching the frozen feel skeleton.** This pass found one, listed as item 7 below. Decide per item.
7. **(Found here) Feint and the end-of-string lockout.**
   - *Reset `LockedUntil` in `CancelString`:* a feinted Heavy no longer owes the cooldown; two red specs go green. Effort: one line plus the cooldown test. It lets a player feint-cycle Heavies faster, so it is a feel call.
   - *Keep it and change the specs:* the lockout is the price of a feint. Effort: two specs.
   - Unblocks: the suite's last non-bot red.
8. **(Found here) Server boot isolation** (A9).
   - *Isolate each `Init` like the client does, and let `AssertBootComplete` name what failed:* a throwing optional System no longer takes the whole server down, but a half-booted server then runs. Effort: small.
   - *Keep it bare:* any failed `Init` stops boot loudly, as now.
   - Unblocks: nothing.

## 6. Independent review

One read-only reviewer, two lenses, over the whole diff (committed range plus the uncommitted A2 hunks).

| Lens | Score | Main findings |
|---|---|---|
| Combat / architecture | **7.5** | The checker missed multi-line calls (it would not have caught the bug it was written for) and helper writes; a live second writer, `AirComboSystem.lua:295`, hid behind that; limiter origin lacked a line; readers (`MovementGuard`, `ParkourSystem`) still read the raw attribute, so `MovementAllowance.Until` has no production caller. |
| Tests | **7** | `AttackAnimations.spec` is partly self-referential once derived; the evade-startup case mirrored the rule; `RateLimiter.spec` could lose its line to Logger's per-message cap; `DefaultMoveRegistry.spec` had an unguarded literal. |

Both lenses were under 8, so the findings were acted on. Done: the checker now parses whole files across line breaks, forwards through `setAttribute`/`extendDeadline`, ignores
block comments, and fails on the pre-fix `DomainSystem` (verified against `git show HEAD:`); the `AirComboSystem` re-assert was removed (every other locker holds a claim); the origin carries the line;
`RateLimiter.spec` waits out the Logger window; the startup case is two cases that set the value; the `Hexagon` literal is guarded. **Not done, and why:** routing the two readers through
`MovementAllowance.Until` (a read-side change in two files for no behaviour gain; `Until` stays, used by its spec); making `AttackAnimations.spec` independent of the module (the baseline ids are authored data
in that module, so pinning them again is exactly the copy that failed). The reviewer was not re-run, so the scores above are from before these fixes.

## 7. Maintenance rules (one per axis)

| Axis | Rule | Enforced by |
|---|---|---|
| A1 | A name or tunable used by two modules lives in one Constants module; consumers alias it (`HitboxEngineConstants.SwingRootedAttribute = AttributeConstants.SwingRooted` is the pattern). | Convention (`SwingFadeSeconds` is the standing exception). |
| A2 | An Attribute with one owner is written only by that owner's file; a new owner is a row in the checker. | `scripts/check-single-writers.py` |
| A3 | A per-frame combat System registers a phase in `CombatTick.PHASES`; a System declares its remotes in `BootManifest`. | `CombatTick.Register` assert; `AssertBootComplete`; `Tests/Boot/BootManifest.spec` |
| A4 | A comment may not cite a module that no longer exists; the count only goes down. | `scripts/check-stale-refs.py` (ratchet at 162) |
| A5 | A module with no non-spec inbound require is deleted or wired. | Re-run the orphan scan (a require-token scan; it found only `HoverLabel`). Not yet a script. |
| A6 | A second copy of a function body that already exists in a sibling is a move into the shared module, in its own commit. | Convention. |
| A7 | A refusal a player can cause either answers the client or leaves a log line; a rate-limit drop logs once per window by construction. | `RateLimiter.spec` |
| A8 | A spec reads authored data (asset ids, shape vocabulary, constants) from the module that owns it. After any run, read the failures from the `TestService:` blocks, not the truncated tree. | `scripts/check-spec-literals.py`; the suite itself |
| A9 | The client boots through `boot()`; a new `Start` is added there, never called bare. | Convention; `Main.client.lua:94` |
| A10 | A new hit-weight flag is added to `Combat_Feedback` and decided in `CombatFeedbackClient`, not read by an FX module. | Convention |
| A11 | A renamed concept is renamed everywhere in one commit, with no behaviour change in it. | Convention |
| A12 | Touching either `*.project.json` means running the checker; a new `Server/` or `Client/` folder is added to `test.project.json`. | `scripts/check-live-project.py`; the load-check in `scripts/run-tests.lua` |

New gate list for a pass: `selene src/`, `stylua --check` on touched files (on LF copies: the checkout is CRLF), `check-logger-scopes.py`, `check-live-project.py`,
`check-single-writers.py`, `check-spec-literals.py`, `check-stale-refs.py`.

## 8. Not verified

- Nothing was played. The `FpsCounter` order change (10000 → `Layers.Debug`), the rate-limit warn volume in a live server, and `MovementAllowance`'s effect on `MovementGuard` are inferred from source.
- The five TrainingBot cases and their cause.
- That removing `AirComboSystem`'s `RootControlLocked` re-assert changes nothing in play: every other locker holds a `RootControl` claim (read from the call sites) and the air-combo specs pass, but no one flew an air combo.
- The `MoveEditorScreen` restore press, which is now uncovered until `Fields.lua` exposes a seam.
