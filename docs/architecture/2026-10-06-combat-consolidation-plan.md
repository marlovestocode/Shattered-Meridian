# Combat Consolidation — Adapted Plan (2026-10-06)

Response to the "Combat Infrastructure Consolidation & Fortification" brief, checked section by section
against `constants-split` @ 7cce1da. The brief assumes a codebase with competing resolvers, legacy V2
modules and a missing pipeline. **This branch mostly isn't that codebase**. The 09-29 rebuild already
deleted the old CombatSystem/HitResolution/HitboxResolver/CombatTypes stack, and the pipeline the brief
draws already exists. So this plan keeps the brief's goals, drops the parts that would build parallel
systems, and spends the effort on the real gaps the audit found.

Scope note (owner, 2026-10-06): M1 step-in and evade clips/sound are **out**.

## What already holds (no work)

| Brief section | Status on this branch |
|---|---|
| 4 One resolution path | **Exists.** `HitboxEngine.OnHit` → `DefenseSystem` (its only subscriber) → `OnResolved` → `DamageSystem` (its only subscriber) → `OnApplied`. That last signal has eight sibling consumers (Grab, AirCombo, Environment, Engagement, PlayerDeath, TrainingBot, KnockbackAudit, DebugDummy). Projectiles enter as ordinary `HitReport`s from inside the engine's substep loop. Realms deliver only through public entry points. |
| 3 Contracts | **Exist under other names.** `HitboxTypes.HitReport` is the context. `DefenseTypes.DefenseOutcome` + `OutcomeKind` (Clean, Blocked, GuardBroken, Backstab, Parried+Perfect, Trade, Evaded) is the result. `DamageTypes.DamageResult` / `CombatFeedback` cover the rest. New `CombatContext`/`CombatResult` modules would be the duplicate the brief forbids. |
| 9, 10 Engine and simulator scope | **Already true.** The engine reports contacts and refuses meaning. The simulator flies shots, and its contacts are judged by the same layers. |
| 7 Timing | **Already one clock.** Every server combat layer is Step-driven with `now` passed down from one Heartbeat, in `Main.server.lua` boot order. Server combat has no `task.wait`, `tick()` or `time()`. Its three `task.delay` calls are animation backstops and a bot respawn. `GetServerTimeNow` is used only where a client must read the deadline (air combo, realm attributes), as documented in `AttributeConstants`. A new CombatClock would be a second clock. |
| 16 Legacy removal | **Nothing to remove.** No V2, legacy, StatusEffect, CharacterState, armor or ragdoll runtime exists. The old move schema's dead blocks were already deleted (`MoveTypes` header). |
| 17 Constants hub | **Mostly done.** `Constants.Combat`, `.Weapons` and `.AnimationIds` are gone, and only stale comments name them. What remains is listed in Phase 3. |
| 18 Layering rules | **Already enforced** by CLAUDE.md's combat-stack rules: one upward seam per layer, siblings over stacked layers, DomainRules instead of a DomainSystem require. |

## What the brief asks for that does not exist — deliberately not built

- **Armor, hyper/super armor, generic i-frames, Untargetable, Executing, StatusEffect system, a
  modifier pipeline with Character/Weapon/Stance/Status stages.** None of these has a mechanic in the game
  today. The `MoveTypes` header records what happened last time: authorable blocks with no runtime were
  "authored, validated, persisted and shown in the editor, and did nothing". Each gets built when a real
  move needs it, as an `OutcomeResolver` input or a `DomainRules`-style reader. Not as scaffolding.
- **Timeline events** (EnableArmor, ApplyStatus, ConsumeResource…). Same reason. The live timeline
  (Windup/Active/Recovery, clip markers, `SpawnDelaySeconds`, the Projectile block firing on Active) is
  already one model, built by `AttackCatalog.Get` and run by `AttackStateMachine`. The Move Editor already
  writes the definitions gameplay uses.
- **A CombatResolver facade.** Wrapping the four layers in one module would add a sixth place to read
  without removing any.
- **"No comments/documentation blocks."** The house rule in CLAUDE.md is header-comment rationale per
  module. New code follows the house rule, kept tight.

## The plan — real gaps, in order

### Phase 1 — Correctness holes the audit found (do first)

**Status: done (2026-10-06).** 1a is in `HitboxEngine` (`isDead`/`livingOwnerOf`; a mid-swing death interrupts
with reason "Died"; `RequestAttack` refuses "Dead"). Grabs and the air combo already released on death, and a
dead player's buffered press was already refused. 1b is `DamageSystem.ApplyImpact`. Feedback goes to the
attacker only, because a defender copy would make their client fake a stun and cut its own swing. 1c is
`AttackRequest.PressId` with a "Refused" verdict on `Attack_Cancelled` and `AttackRequestSystem.OnPressRefused`.
A superseded press hands its prediction to the newer press rather than cutting it, so mashed strings don't
stutter. Duplicate ids are dropped per character.

**1a. Death does not gate combat.** No layer checks `Health <= 0`. A player killed mid-swing keeps their
Active window live until the character is removed. A corpse can still be hit, which can trigger
combo escalation, engagement tags, damage numbers and grab triggers.
- Engine candidate filter skips targets whose Humanoid is dead (`CharacterUtil.LiveHumanoidOf`).
- On death, cancel that body's swing through the existing `HitboxEngine.CancelAttack(id, "Died", now)`,
  drop its buffered press (`AttackRequestSystem`), and release any grab and air-combo hold it is part of.
  The death edge comes from one place: the registration's `Humanoid.Died`. No new death owner;
  `PlayerDeathSystem` still owns credit.
- Specs: dying mid-swing hits nothing more; a corpse takes no contact; a dead grabber releases.

**1b. Grab throw damage is a side door.** `GrabSystem.landFlight` calls `TakeDamage` directly for both
self-impact and the struck bystander. That bypasses `OnApplied`, so there is no kill credit, no
engagement tag, no feedback or damage number, and no realm damage scaling.
- Add one narrow seam: `DamageSystem.ApplyImpact(source, target, amount, at)`. It prices through the same
  realm scaling, publishes `OnApplied` and sends feedback, but skips defence. A thrown body was never
  blockable, so this keeps current behaviour. Grab's two `TakeDamage` calls move onto it.
- Specs: a throw kill credits the thrower; a bystander hit shows feedback and is realm-scaled.

**1c. Attack presses reconcile by timeout only.** A press the server refuses keeps its predicted swing on
screen for two pings + `Input.BufferSeconds` + 0.1s before it is cut. The parry path already solved this
with a press id and a verdict (`DefenseSystem` notifyClient).
- Give `AttackRequest` the same `PressId`. On a refusal the server answers it with the reason,
  piggybacking `Attack_Cancelled` rather than adding a remote. The client cuts its prediction on the
  verdict and keeps the timeout only as a backstop. This also dedupes a retransmitted press.
- Specs: a refused press is answered; a duplicate id is ignored.

### Phase 2 — Consolidate what is split today

**Status: done (2026-10-06).**
- 2a: `ResolveInput.GuardDisabled`. The held-body and NoBlock rules are now inside `OutcomeResolver.Resolve`,
  and the precedence is pinned by one table spec.
- 2b: `HitReport.Source` (`HitboxTypes.ContactSource`), stamped by the engine, the simulator and
  `ApplyImpact`, and read through `HitboxTypes.SourceOf`/`IsShot`. Correction to the count below: five sites
  were inferring the source. The other matches either need the projectile record itself, or are move-role
  lookups (`AirComboMoves.RoleOf`, `isBasicMoveId`) that are correctly keyed by MoveId. Those stay.
- 2c: `DamageResolver.ApplyScales`. The shot and realm scales are one ordered pure chain, and
  `ApplyImpact` uses the same chain.

**2a. Defence precedence in one function.** `OutcomeResolver.Resolve` owns the ladder (Evaded → Parry →
Block/Backstab/GuardBroken → Clean), but three overrides are bolted on afterwards in
`DefenseSystem.onHit`: air-held, stun-held and realm NoBlock all turn a guard result into Clean. Realm
NoParry and unparryable shots are folded into `ParryConsumed`. Move these into resolver inputs
(`GuardDisabled`, `ParryDisabled`) so the whole precedence is one pure function with one spec table.
Clash/Trade stay in the two arbitration passes, which are batch-level by nature.

**2b. A contact says where it came from.** Eighteen sites infer the source from shape:
`Report.Projectile ~= nil`, `projectile.DomainId ~= nil`, `AirComboMoves.RoleOf`, `isBasicMoveId`,
`string.find(MoveId, ":Heavy:")`. Add one `Source` field to `HitReport` (`"Melee" | "Projectile" |
"Realm" | "Throw"`), stamped by whoever creates the report, and carry it onto `DefenseOutcome`. Then
migrate the inference sites. Pairs with 1b, since `ApplyImpact` is the "Throw" source.

**2c. The damage multiplier chain has one owner.** Today `DamageResolver` applies combo, backstab and
stagger mitigation, while `DamageSystem.applyOutcome` applies projectile `DamageScale`, four realm scales
and the air-combo hook inline. Move the ordered chain into `DamageResolver` (base → outcome → source scale
→ realm → air combo) so every number lives in one pure function with one spec. **No new stages**:
character, weapon and status stages wait for the progression work, where they get a real input.

### Phase 3 — Constants and dependency direction

- `DefenseConstants`, `HitboxEngineConstants` and `CombatConstants` require `Shared/Constants.lua`. A
  domain constants file depending on the hub runs upward. Point them at `AttributeConstants` (or the
  specific leaf) directly.
- Combat modules reach through the hub's re-exports: `Constants.Attributes` in 25 files, `Constants.FX`
  in 13, `Constants.Run` in 3, and `.Debug` and `.Network` in 1 each. Migrate the combat folders to
  direct leaf requires, then delete each re-export once a repo-wide grep shows no callers. Non-combat
  callers move in the same pass, or that re-export stays.
- Sweep the stale "Constants.Combat" comments.

### Phase 4 — "Why did this attack fail?" (extends Live Console, no new tooling)

The Move Editor's `HitLog` sees only contacts that resolved, and only for the move under test. Nothing
records the misses that matter: a refused press and its reason, a contact that never happened, or a
parry that missed because the window had closed or the realm forbade it.
- A server-side ring buffer (`CombatTrace`, behind `DebugConstants`, off by default). Each record holds:
  press → accepted or refused(reason) → contacts → defence kind + the resolver inputs that decided it
  (state at contact, arc, guard, window open/consumed/disabled, rewind hold applied) → damage → stun
  (linked or authored) → cancel reason.
- Fed from the existing `debugLog` points, so no layer learns about the tracer. Shown as a Live Console
  (F5) tab. The existing per-layer debug flags stay.

### Phase 5 — Tests for the brief's matrix

Coverage is already broad: 53 combat specs, with parry/block/clash/projectile/realm/grab all present.
Add only what is missing:
- the Phase 1 cases: death mid-swing, corpse, dead grabber, throw credit, refused press, duplicate press;
- one `OutcomeResolver` precedence table after 2a, covering every input combination's kind;
- **respawn** (zero specs touch it): a new character after a death mid-string starts clean, with no stun,
  stagger or buffered press;
- **hitch**: one Step with a 0.5s delta mid-swing neither double-hits nor skips the Active window (the
  engine's substep cap should already guarantee this; pin it).

## Order and size

Phase 1 is three small, separate changes and can ship one at a time. Phase 2a/2b/2c are each a
refactor with no behaviour change, pinned by the specs first. Phase 3 is mechanical. Phase 4 is new,
but optional, and fed by what exists. Every phase keeps current combat behaviour except the Phase 1
bug fixes.

Blocker carried from the last pass: the TestEZ suite needs Studio (`run-in-roblox`), so each phase
should be run locally before the next one starts.
