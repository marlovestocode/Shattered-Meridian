# Attack & Damage Layer — Implementation Plan

Status: proposed, not built. Written against `progression-spine` after `HitboxEngine` and
`DefenseSystem` both landed.

## Context

Two clean layers exist today, each ignorant of the one above it:

```
HitboxEngine     where the volume is, who is inside it        (built, solid)
DefenseSystem    what kind of hit that was                    (built, solid)
(nothing yet)    how much it hurts, what it does to you        <- the gap
```

`DefenseSystem` (`Server/Combat/Defense/DefenseSystem.lua`) subscribes to `HitboxEngine.OnHit`,
classifies each contact as `Clean | Blocked | GuardBroken | Backstab | Parried | Trade`, and stops.
It applies no damage, owns no health, no posture, no combo state. When this plan's layer is built it
subscribes to `DefenseSystem.OnResolved` the same way `DefenseSystem` subscribes to `OnHit`, and
neither of the two built layers is rewritten to accommodate it.

**There is currently no code path that can throw a real attack.** `HitboxEngine.RequestAttack` has
exactly one caller today: `Server/Combat/TestAttackHarness.lua`, explicitly temporary, one flat test
swing with no combo, no charge, no per-weapon variation, registered so `DefenseSystem`'s
classification could be exercised before a real attack layer existed. It is deleted the moment this
plan's attack layer ships. `Client/Combat/CombatClient.lua` and `Client/Combat/HotbarMoveClient.lua`
were both deleted in the teardown and are not being resurrected as-is.

This plan is therefore two systems, not one, because the repo owner's own ask separates them:

- **The attack layer** — what the player is trying to throw, whether they're currently allowed to,
  which stage of a string comes next, and the client-facing responsiveness policy around all of that.
- **The damage layer** — what owns health, posture, and combo *escalation* state; the first real
  consumer of `DefenseSystem.OnResolved`.

They are separate modules with a narrow, one-directional relationship (the attack layer *queries* the
damage layer's combo-escalation state when picking what to throw next; the damage layer never calls
into the attack layer at all), not one fused system — see "Where it lives" below for why splitting
them mirrors `HitboxEngine`/`DefenseSystem`'s own boundary discipline rather than re-fusing what the
teardown deliberately pulled apart.

### What this pass found that the brief didn't mention

Four structural facts surfaced while reading the current tree in full. None of them are fixed here —
this is a design pass, not implementation — but each one materially shapes the plan below, so they are
named rather than silently designed around.

**1. `CombatTypes.lua` is dead documentation, and unusually good prior art.**
`Server/Combat/CombatTypes.lua` still exists on disk. Every module it was written to type
(`CombatSystem.lua`, `HitResolution.lua`, `AirCombo.lua`, `RagdollController.lua`, `DummyCombat.lua`,
`BotCombat.lua`) has been deleted, and nothing live requires it. It is not touched by this plan, but it
*is* cited throughout — its `comboIndex`/`basicSwingIndex`/`basicComboLanded` split, its single
`attackEndsAt` commitment lock, and its `bufferedAttack` input-buffering shape are the closest thing
this codebase has to a previously-tuned answer for exactly the questions this plan has to answer fresh.
Where this plan reuses that shape, it says so; where it deliberately diverges, it says why.

**2. The Move Creation System is a fully-built authoring pipeline with no live combat consumer, and
its own file headers already say so.** `MoveRegistryManager.lua`, `DefaultMoveRegistry.lua`,
`MoveTypes.lua`, `MoveStats.lua`, `MoveEditorSystem.lua`, and the entire `Client/UI/Screens/DevTools/MoveEditor/`
tree are alive, wired to `ArtSystem`/`ArtTreeManager` (an "Art" *is* a `MoveDefinition` with an
`Art` binding — `MoveTypes.lua`'s own header), persisted to DataStore, and booted in
`Main.server.lua`. `MoveEditorSystem.lua`'s own header states plainly: *"No longer owns (combat system
removed): TestFireMove/SpawnPreviewDummy... Move creation/editing/saving/validation/listing... is
untouched by that removal."* `MoveTypes.ToHitboxAttackDefinition` projects a `MoveDefinition` onto
`Types.HitboxAttackDefinition` — the *old* combat system's schema (`Size`/`Radius`/`Damage`/
`PostureDamage`/`Knockback`/`Projectile`/`ObjectStun`, keyed by nothing `HitboxEngine` understands).
`HitboxEngine` consumes a different, fresh schema (`HitboxTypes.AttackDefinition` —
`BaseDimensions`/`Scaling`/`Offset`/`AttachmentPart`, deliberately carrying no damage field at all, per
that file's own header). **These are two different shapes with no bridge between them today.** This
plan proposes one (see "The Move Creation System bridge" below) rather than building a second,
parallel attack-authoring path — see that section for the reasoning and the alternative it rejects.

**3. `HitReport` carries no move identity.** `HitboxTypes.HitReport` — the one thing `HitboxEngine`
answers a contact with — carries `Attacker`/`Target`/`TargetPart`/`Shape`/`Dimensions`/
`ContactPosition`/`ComboStage`/`PowerLevel`/`SampleTime`. There is no field a damage layer could use to
look up "what move was this" in any catalogue. `AttackDefinition.DebugName` already exists for
exactly this identifying purpose (per its own name, and per the engine's own debug logging use of it)
but is not threaded onto `HitReport`. See "Integration seam: `HitReport.DebugName`" — this is the one
place this plan asks `HitboxEngine` to change.

**4. Two more `Server/Combat/` siblings are already orphaned the same way `TestAttackHarness` will be
once this plan ships, and one adjacent file's documentation is now actively wrong.**
`ObjectStunResolver.lua` and `Movement.lua` both still exist, are both well-written, and both have
*zero* live callers — their only caller was `CombatSystem.lua`'s own `Heartbeat`, and it's gone. Grepping
the tree confirms neither is required from anywhere outside its own spec. Separately,
`StarterCharacterScripts/Health.server.lua`'s header describes a passive-health-regen system
(`Server/Combat/HealthRegen.lua`, driven by "`CombatSystem`'s Heartbeat") that was deleted in this same
teardown — the comment is now stale and describes a mechanism that no longer exists. None of these four
are this plan's job to fix. They're named here because a damage layer that reads this codebase's history
for prior art (as this plan does, at length) needs to know which of it is *live* and which is
archaeology, and because `ObjectStunResolver` in particular is real, tested, working code this plan
could plausibly want to re-wire later — worth a deliberate decision when that day comes, not a surprised
rediscovery.

---

## Where it lives

```
src/ReplicatedStorage/Shared/Damage/
    DamageTypes.lua           -- DamageOutcome, ComboEscalationState, HitstunState, AttackCatalogEntry
    DamageConstants.lua       -- hitstun duration, combo window, posture tuning (see "Posture" below)

src/ServerScriptService/Server/Combat/
    AttackCatalog.lua         -- MoveId -> {geometry for HitboxEngine, damage/posture/knockback for
                                 the damage layer}. Shared by both systems below; belongs at this level
                                 (a sibling of HitboxEngine/ and Defense/, not nested in either) because
                                 neither owns it exclusively -- see "The Move Creation System bridge".

    Attack/
        SwingSequencer.lua     -- per-combatant "which stage throws next" (throw-based, mirrors the
                                   dead CombatTypes.basicSwingIndex)
        AttackRequestSystem.lua -- public module: the remote, input buffering, gating through
                                   DefenseSystem.CanAttack + DamageSystem.CanAttack, calls
                                   HitboxEngine.RequestAttack, sends Attack_Started

    Damage/
        VitalsMeter.lua         -- health (thin wrapper over Humanoid.Health/TakeDamage -- see
                                   "Health stays where it already lives") + posture pool, mirrors
                                   GuardMeter's pure-math/stateful-holder split
        ComboEscalation.lua     -- per-combatant landed-hit combo state: stage, window expiry,
                                   launcher/finisher unlock. NOT a segmented state machine like
                                   DefenseStateMachine -- see "Why this isn't a state machine"
        DamageResolver.lua      -- pure: (DefenseOutcome, AttackCatalogEntry, ComboEscalationState) ->
                                   DamageResult
        DamageSystem.lua        -- public module: the DefenseSystem.OnResolved subscription, the
                                   registry, CanAttack query, hitstun-cancels-own-swing, the feedback
                                   remote, the Heartbeat

src/StarterPlayer/StarterPlayerScripts/Client/Combat/
    AttackInputClient.lua      -- rebuilt input listener: keybinds (Constants.Keybinds, unchanged),
                                   optimistic local windup presentation, fires Attack_Request, listens
                                   for Attack_Started/Combat_Feedback
    HotbarMoveClient.lua       -- rebuilt: resolves a hotbar press through HotbarBindings.Get(slot)
                                   into the same Attack_Request shape as a weapon-stage press

src/Tests/Combat/
    Attack/SwingSequencer.spec.lua
    Attack/AttackRequestSystem.spec.lua
    Damage/VitalsMeter.spec.lua
    Damage/ComboEscalation.spec.lua
    Damage/DamageResolver.spec.lua
    Damage/DamageSystem.spec.lua
    AttackCatalog.spec.lua
```

`HotbarBindings.lua` (`Client/Combat/HotbarBindings.lua`) is untouched — it already holds the
session-scoped slot→MoveId mapping and needs no changes; it was waiting for a reader, and
`HotbarMoveClient.lua` is that reader.

`TestAttackHarness.lua` and `TestAttackHarnessClient.lua` are deleted the moment
`AttackRequestSystem`/`AttackInputClient` boot — per their own header, that was always the plan.

`DamageResolver` is pure for the same reason `OutcomeResolver` is: every interesting rule (how much
does this hit cost, does it break posture, does it extend the combo window) is a decision about a
handful of numbers, and a pure resolver means all of it is table-driven testable with no rig.

---

## Integration seam: `HitReport.DebugName`

**This plan requires a small `HitboxEngine` change**, in the same spirit as the parry/block plan's
`CancelAttack(reason, now)` addition: additive, backward-compatible, and impossible to do quietly
later once callers exist.

`HitboxTypes.HitReport` gets one new field:

```lua
export type HitReport = {
	Attacker: Model,
	Target: Model,
	TargetPart: BasePart,
	Shape: ShapeKind,
	Dimensions: Dimensions,
	ContactPosition: Vector3,
	ComboStage: number,
	PowerLevel: number,
	SampleTime: number,
	DebugName: string,   -- NEW
}
```

Populated in `HitboxEngine.reportHit` from `record.Swing.Definition.DebugName`, which the engine
already reads for its own logging (`beginActiveWindow`/`endSwing`'s `logger:debug` calls) — this is
not new data, only a new place the engine already-known data is exposed. `DefenseOutcome` already
carries the whole `HitReport` through unmodified (`Report: HitboxTypes.HitReport` on
`DefenseTypes.DefenseOutcome`), so this one field addition is the entire seam: `DamageSystem`'s
`OnResolved` handler reads `outcome.Report.DebugName` and has everything it needs to look the attack
up in `AttackCatalog`.

This keeps the engine's own domain-agnostic rule intact — `DebugName` is exactly the same kind of
opaque passthrough `ComboStage`/`PowerLevel` already are (see `HitReport`'s own header: *"Carried
straight through from RequestAttack, untouched. The engine scales with them and never interprets
them"*). The engine still never learns what a "move" is; it just stops discarding a string it was
already carrying around for its own logs.

Without this, the damage layer has no way to know *which* attack landed, only its raw geometry and two
opaque numbers — which would force either a second, parallel attack registry keyed by something the
engine does understand (a non-starter, since nothing on `HitReport` is a stable per-move key), or
deriving damage purely from `PowerLevel` arithmetic, which throws away every per-move authored value
the Move Creation System already has a full editor, DataStore persistence, and balance-graphing tool
(`MoveStats.lua`) built around.

---

## The Move Creation System bridge

Given finding 2 above, the real question this plan has to answer isn't "how does the damage layer get
damage numbers" — it's "does the new attack layer feed itself from the existing, fully-built Move
Creation System, or does it grow a second, parallel one."

### Option A — a new, minimal `AttackCatalog` authored directly against the engine's schema

A flat table, hand-authored, mapping `MoveId -> HitboxTypes.AttackDefinition + damage numbers`,
bypassing `MoveRegistryManager`/`MoveTypes` entirely.

*Why not.* This duplicates a schema, a validation/clamp pass, and a persistence story that already
exist and are already exercised by a real editor UI. It leaves `MoveEditorSystem`, the entire
`Client/UI/Screens/DevTools/MoveEditor/` tree, and — critically — `ArtSystem`'s `MoveArtBinding` orphaned a
second time. Since an Art *is* a move (`MoveTypes.MoveArtBinding`'s own header: *"This is the entire
Move-Creation-System-to-ArtSystem seam"*), building attacks any other way means the progression layer's
entire ability system has no path to ever deal damage — directly contradicting the instruction to set
combat up "before more is built on top." It also violates the standing rule against duplicating combat
infrastructure that already exists.

### Option B (recommended) — bridge `MoveDefinition` into the engine's schema with one new projection

Add `MoveTypes.ToEngineAttackDefinition(move: MoveDefinition): (HitboxTypes.AttackDefinition, DamageProfile)`
alongside the existing (and now legacy) `ToHitboxAttackDefinition`. `AttackCatalog.Get(moveId)` calls
`MoveRegistryManager.Get(moveId)` first, falls back to `DefaultMoveRegistry.Get(moveId)` (mirroring
whatever dual-lookup `MoveEditorSystem` already does for its own `List`/`ListDefaultMoves` split), and
projects the result once through the new function.

```lua
export type DamageProfile = {
	Damage: number,
	PostureDamage: number,
	Knockback: MoveTypes.MoveKnockback?,
}
```

This reconnects the whole existing pipeline — editor UI, DataStore persistence, Art bindings,
`MoveStats`'s balance graphing — with one new pure function and zero changes to the editor itself.
`MoveRegistryManager.Upsert`/`Delete` already mutate the live in-memory registry synchronously, so
`AttackCatalog` needs no cache invalidation of its own — a `Get` at throw time is already cheap (move
counts are "tens, not thousands," per `MoveEditorSystem`'s own header) and always current.

Two known gaps in the projection, neither blocking:

- **`ScalingProfile` has no authored counterpart on `MoveDefinition`.** Nothing in the Move Creation
  System today authors a combo-stage/charge growth curve. `ToEngineAttackDefinition` defaults every
  projected move to a flat, non-scaling profile (`ComboStageMultipliers = {1}`,
  `PowerMultiplierPerUnit = 0`, `ChargeSeconds = 0`). A move that wants hitbox growth with combo depth
  or a charge-up needs the Move Editor to grow those fields first — out of scope here, but the
  projection function is the seam a future Move Editor pass hangs off, not a rewrite.
- **Five shapes have no `HitboxEngine` equivalent.** `HitboxTypes.ShapeKind` is seven shapes; the Move
  Creation System's `HitboxShapes.ShapeId` is twelve (`Disc`/`Wedge`/`Pyramid`/`Blade`/`Slice` have no
  engine-side analytic containment test — see `HitboxTypes.lua`'s own header on why those five were
  deliberately dropped from the engine's vocabulary). `ToEngineAttackDefinition` falls back to `Box`
  for any of the five, logged the same "corrected, not crashed" way `HitboxTypes.SanitizeDefinition`
  already handles a malformed shape.

This is a real scope decision, not a slam dunk — reconnecting a live, DataStore-backed system carries
more surface than authoring a fresh table would. It's called out explicitly in Open Questions rather
than assumed.

---

## The attack layer

### `SwingSequencer` — per-combatant "what throws next"

Throw-based, not landing-based, mirroring the dead `CombatTypes.basicSwingIndex` exactly: it advances
on every *accepted* `RequestAttack`, whiff or not, so a player sees the string cycle even while
missing, and resets after `DamageConstants.SwingResetSeconds` of no accepted throw. This is
**request-side** state — it decides which `MoveId` gets thrown on the next press, before `HitboxEngine`
or `DefenseSystem` have any opinion about the outcome. It is not the same thing as combo *escalation*
(below), and conflating the two is exactly the mistake the old design's own split existed to avoid —
see `CombatTypes.lua`'s own header on why `basicSwingIndex` (throw-based, drives which animation plays)
and `basicComboLanded` (landing-based, gates the finisher) were deliberately two counters, never one.

`SwingSequencer` is queried by `AttackRequestSystem` when a request arrives (`GetNextMoveId(model,
weaponId, category)`) and is the *only* place "which stage" is decided. `HitboxEngine`'s own
`ComboStage` parameter (fed into `RequestAttack`) is a separate, complementary number — it scales a
*single* attack's hitbox by how deep into an unbroken string the attacker currently is (read from
`ComboEscalation`, below, at throw time), independent of which distinct `MoveId` `SwingSequencer` picked
for this press. The two mechanisms can and should coexist: stage-select decides *which* move, engine
`ComboStage` decides how *big* that move's volume is for this particular throw.

### `AttackRequestSystem` — the request/gating/confirmation loop

One `RemoteEvent`, `Attack_Request`, client → server. Payload is an action selector only — `"Basic"`,
`"Heavy"`, or `{ HotbarSlot: number }` — **never a target, a position, a direction, or a client
timestamp**. This matches `HitboxEngine`'s own "the pose is never baked, resolved live every sample"
discipline and `TestAttackHarness`'s own zero-payload precedent: the server derives everything
geometric from the character's own live rig, and derives *timing* from its own arrival clock, never
from anything the client claims about when it pressed.

On receipt:

1. Rate-limited (`RateLimiter`, its own bucket — see "RemoteEvent shape and call frequency" below).
2. `SwingSequencer.GetNextMoveId(...)` resolves which `MoveId` this press means.
3. Gated through **both** `DefenseSystem.CanAttack(model)` (existing, unconsumed today — this is its
   first real caller) **and** the new `DamageSystem.CanAttack(model)` (hitstun — see "Combo chain
   priority" below). Either refusal is buffered, not dropped — see "Input buffering."
4. `AttackCatalog.Get(moveId)` resolves the `HitboxTypes.AttackDefinition`.
5. `HitboxEngine.RequestAttack(combatantId, definition, comboStage, powerLevel)` — `comboStage` read
   from `ComboEscalation.GetStage(model)`, `powerLevel` authored per move (a flat number today; the
   old weight-class distinction between a jab and a heavy lived in `PowerLevel` before and can again).
6. On acceptance, `SwingSequencer.Advance(model)` and `Attack_Started` fires to the attacker only.

`Attack_Started`'s payload deliberately mirrors the dead `Types.AttackStartedPayload` almost field for
field (`DebugName`/`WindupSeconds`/`ActiveSeconds`/`RecoverySeconds`/`ComboStage`/`CooldownSeconds`) —
that shape was already right for its one job (letting the client's animation/FX layer sync to what the
server actually scheduled) and nothing about the new engine changes what that job needs.

---

## The damage layer

### Health stays where it already lives

`Health.server.lua`'s standing rule holds and this plan does not reopen it: `Humanoid.Health` is
authoritative, never shadow-tracked as a second number. `VitalsMeter`'s health half is a thin wrapper —
`Humanoid:TakeDamage(amount)` and `Humanoid.Health` reads — not a parallel pool. This also means death
itself is unchanged: `Humanoid.Died` still fires, `PlayerDeathSystem` still owns confirming it (see
"Kill attribution," below, for the one gap that needs closing there).

### Posture — a real open question, not a given

The dead `CombatTypes.CombatVitalsState` carried `posture`/`maxPosture`/`postureBrokenExpiry` as a
resource *distinct from* `DefenseSystem`'s own `Guard` meter. They are not the same mechanic wearing
two names: `Guard` only ever changes while a player is actively blocking (spent on a mitigated hit,
restored on a parry) — it is purely a defense-side resource. The old `Posture` built up from **being
hit at all**, blocked or not, and a full bar meant a guaranteed stagger opening regardless of whether
the victim ever raised a guard. That is what makes a Sekiro-style posture system bite a turtling
opponent who never blocks — something `Guard` structurally cannot do, since `Guard` never moves for a
player who never blocks.

This plan's `VitalsMeter` includes a `Posture` pool built on exactly that premise (drains toward zero
on *every* connecting hit — Clean, Backstab, GuardBroken, and a fraction of Blocked — full depletion
triggers a `PostureBroken` opening, a short window of guaranteed-Backstab-arc vulnerability), because
the genre convention this codebase already leans on throughout (`Constants.Keybinds`' own comments cite
Souls-likes repeatedly) implies it, and because "everything should be defendable" reads as an argument
*for* a mechanic that punishes never engaging defense, not against one. But this is a real feel/scope
call, not a structural inevitability — flagged explicitly in Open Questions rather than assumed, since
it is entirely legitimate for the repo owner to decide `Guard` alone is the intended single resource
and a second meter is scope this plan shouldn't add on its own authority.

### `ComboEscalation` — landed-hit combo state, and why it isn't a state machine

Per combatant, per attacker: a stage counter, a window-expiry timestamp, and a launcher/finisher-unlock
flag. Advances **only** on a hit `DamageResolver` classifies as genuinely landed (Clean, Backstab,
GuardBroken) — never on Blocked, never on a whiff (whiffs never reach `OnResolved` at all, since
`HitboxEngine` only reports contacts). This is the landing-based half of the old
`basicSwingIndex`/`basicComboLanded` split, and it deliberately does **not** grow up into a segmented
state machine the way `DefenseStateMachine` did.

`DefenseStateMachine`'s segment history exists to answer *"what was your posture at an arbitrary past
SampleTime,"* because `DefenseSystem`'s pass 1 has to classify a contact against a defender's posture
*as it stood the instant that contact landed*, which can be earlier than "now" by a full substep batch.
`ComboEscalation` never needs that retroactive query — it is not classifying an *incoming* contact
against a moving window, it is an *output* effect applied once, in `DefenseSystem`'s own pass-2 order,
per already-resolved outcome. A flat, timestamp-driven record (`stage`, `windowExpiresAt`,
`math.max`-extended on every landed hit, read fresh at the next `SwingSequencer` query) is the
proportionate amount of machinery, matching `GuardMeter`'s own "stateful half does no arithmetic of its
own" restraint rather than `DefenseStateMachine`'s heavier shape. Building the heavier shape here would
be exactly the kind of complexity `HitboxEngineConstants`' own header warns against: solving a problem
(sub-frame retroactive queries) this state doesn't have.

### `DamageResolver` — pure, one contact at a time

```lua
function DamageResolver.Resolve(outcome: DefenseOutcome, attack: AttackCatalogEntry, escalation: ComboEscalationState): DamageResult
```

Applies the outcome-kind rules directly rather than re-deriving them:

- **Clean / Backstab** — full `Damage`/`PostureDamage`, `ComboEscalation` advances, `Hitstun` applied
  to the defender (see below).
- **GuardBroken** — full damage (the guard is gone; per `OutcomeResolver`'s own contract `GuardBroken`
  is a real opening, not a discount), `ComboEscalation` advances.
- **Blocked** — no health damage, a fraction of `PostureDamage` still applies to Posture (per the
  premise above — mitigation should not be free against the *posture* resource even though `Guard`
  already priced it for the *guard* resource), **no** `ComboEscalation` advance and **no window
  extension** — landing on a raised guard denies the attacker escalation credit but does not reset
  their string; see "Combo chain priority" for the reasoning.
- **Parried / Trade** — no damage applied by this layer at all; `DefenseSystem` already staggered the
  attacker and cancelled their swing. `DamageResolver` still records the `Trade`/`Parried` outcome for
  feedback purposes (so both clients get an accurate `Combat_Feedback` event) but moves no health or
  posture.

### `DamageSystem` — the public module

Structurally mirrors `DefenseSystem.lua`: a registry (`RegisterCombatant`, matching
`HitboxEngine`/`DefenseSystem`'s own model/root/humanoid shape so a player, a bot, and a dummy go
through one path), a subscription (`DefenseSystem.OnResolved`), a query (`CanAttack`), an output signal
(`OnApplied`, for anything downstream that wants to react to real damage — `RewardSystem`,
`AchievementSystem`, eventually), and its own `Heartbeat` for Posture regeneration and Hitstun/window
expiry — connected **after** `DefenseSystem`'s own, for the identical reason `DefenseSystem`'s
`Heartbeat` must run after `HitboxEngine`'s: it consumes a signal produced earlier in the same frame,
and Roblox fires `Heartbeat` connections in connection order.

Unlike `DefenseSystem`, **this layer does not need a two-pass model.** `DefenseSystem`'s two passes
exist for two specific reasons — SampleTime-accurate window classification (pass 1) and Trade
arbitration across a whole batch (pass 2) — and neither reason applies here. `DamageSystem` subscribes
to `OnResolved`, which fires from *inside* `DefenseSystem`'s own already-arbitrated pass 2: by the time
`DamageSystem` sees a contact, `DefenseSystem` has already decided everything time-sensitive about it.
And unlike `Guard`'s restore-on-parry, nothing this layer grants (damage, posture drain, hitstun) is a
resource a naive immediate-apply could be exploited into double-granting by reordering — see "Combo
chain priority" for why the symmetric-trade case this might seem to need falls out for free instead.

---

## Combo chain priority under latency

This is the concrete gap the brief names — parry priority and block priority are `DefenseSystem`'s
already-solved territory; this section is new ground.

**Framing: combo state is per-attacker, never shared or contested.** Two players fighting each other
each own their own independent `SwingSequencer`/`ComboEscalation` records — there is no shared pool
either draws from, so "who gets the combo chain" is never a question of arbitrating between two
competing claims on one resource. The only way one combatant's combo state is ever perturbed by
*another* combatant is through a resolved hit, which is exactly what the rest of this section works
through.

### Case 1 — does a Blocked or Parried hit interrupt the *attacker's own* progression?

**Parried: yes, but for free, with no special-cased rule needed.** `DefenseSystem` already cancels the
attacker's swing (`HitboxEngine.CancelAttack`) and staggers them (`DefenseStateMachine.Stagger`,
`DefenseConstants.Stagger.DurationSeconds`, currently 1.5s per the parry/block plan). `DamageSystem`
does not need its own "reset combo on parried" rule at all, provided `ComboEscalation`'s own window
(`DamageConstants.ComboWindowSeconds`) is tuned **shorter** than the stagger duration — by the time a
parried attacker can act again, their own escalation window has already lapsed on its own. This is the
same kind of "let the timer expire, don't special-case it" economy `DefenseStateMachine.CanArmParryAt`
already practices with its own lockout timestamps. Concretely: propose `ComboWindowSeconds` in the
0.8–1.0s range (the old design's per-hit combo-reset windows lived in comparable territory), strictly
below the 1.5s stagger, and flag the *relationship* — not just the number — as something worth
re-confirming once the stagger duration itself is settled (it is already an open question in the
parry/block plan).

**Blocked: no swing cancellation, no escalation credit, no window reset.** The attacker's swing is
never touched by a block — `HitboxEngine`/`DefenseSystem` have no mechanism that would cancel it, and
this plan adds none. `SwingSequencer` still advances on the accepted throw (the visual string keeps
cycling — a blocked Basic1 still lets the player throw Basic2 next), but `ComboEscalation` does not
(no launcher/finisher progress, no damage-scaling growth, per `DamageResolver`'s Blocked branch above).
This directly answers the parry/block plan's own open question 4 ("does a blocked hit still advance the
attacker's combo") with a firmer answer than that plan's tentative "yes-with-reduced-advancement" lean:
**no advancement at all**, because a defender who successfully raises a guard should get an
unambiguous answer to "did that actually work" — a partial-credit model muddies exactly the readability
this codebase's own combat philosophy asks for. The cheaper, reduced-credit alternative is real and
legitimate (less punishing for the attacker, easier to tune around a long combo string) and is listed
in Open Questions rather than foreclosed.

### Case 2 — two attackers land Clean hits on each other in the same resolution batch

**No `Trade`-equivalent is built for this, deliberately, and the reasoning is different from why
`Trade` exists for parries.** `OutcomeResolver.ArbitrateTrades` exists because a *naive* independent
application of two mutual parries is exploitable: both parriers would independently receive
`ParryRestore`, letting two players farm guard by parrying each other on purpose — a real, stated
concern in the parry/block plan (*"a trade must cost a swing each and change no resource"*). Nothing
in this layer has an equivalent exploit surface. Damage and posture drain are not a pool either side
can "farm" by trading — they're costs, not rewards, and applying them independently and symmetrically
to both contacts in the same batch already produces the fair outcome a special-cased arbitration would
otherwise exist to guarantee. Whoever's hit did more damage "wins" the exchange in the only sense that
matters (the health totals), and that's not a rule this system enforces — it's just what happens when
each side's numbers are applied honestly.

What *is* new here — and where the actual design work is — is **hitstun**.

### Case 3 — hitstun cancels the *defender's own* in-flight swing (which is what makes trading real)

Today, nothing cancels a swing in response to being hit — only `Parried` cancels a swing, and only the
*attacker's*. A player who is mid-swing when struck by an ordinary Clean hit currently keeps swinging
uninterrupted, which is not the outcome any action-combat reference point (this codebase's own,
Souls-adjacent, per `Constants.Keybinds`' comments) actually wants: a real counter-hit should be able to
stop an opponent's own combo, not just cost them health in parallel to it continuing.

**Proposed rule:** any hit `DamageResolver` classifies as Clean, Backstab, or GuardBroken applies
`Hitstun` to the *defender* — a short lockout (`DamageConstants.HitstunSeconds`, proposed ~0.4–0.5s,
in the neighborhood of the old, historically-derived `HitStunDuration = 0.6` the 2026-08 audit's combat
balance section cites — see that document's §6.1 for the derivation this plan borrows the order of
magnitude from, though the number itself needs fresh tuning against whatever `WindupSeconds` the
rebuilt move set actually authors). While hitstunned:

- If the defender was themselves mid-swing (`AttackStateMachine` state ≠ `Idle`) at the moment of
  contact, `DamageSystem` calls `HitboxEngine.CancelAttack(defenderCombatantId, "Hitstun",
  contact.SampleTime)` — **the same call `DefenseSystem` already makes for a parried attacker,
  reused for a new reason.**
- `DamageSystem.CanAttack(model)` refuses until hitstun clears, consulted by `AttackRequestSystem`
  alongside `DefenseSystem.CanAttack`.

This is applied per-contact, in the same `SampleTime` order `DefenseSystem`'s own pass 2 already
iterates the batch in — `DamageSystem` reuses that ordering rather than inventing a second one, the
same "don't re-litigate a solved ordering question" discipline the parry/block plan itself follows for
its own `SampleTime`-based classification. Cancellation is idempotent
(`AttackStateMachine.Interrupt` on an already-`Idle` machine is a documented no-op), so a combatant hit
twice in one batch by two different attackers is cancelled at most meaningfully once.

**This directly answers "can a defender's hit-reaction preempt an attacker who's mid-combo": yes, and
symmetrically.** If A is mid-string against B and B lands a counter-hit on A while A is still swinging,
A's swing is cancelled — landing your own hit is a legitimate, timing-based way to interrupt an
opponent's combo, with no block or parry required. If both A and B are mid-swing and connect on each
other in the same batch (the literal "two Clean hits" case from Case 2), **both** get hitstunned and
**both** swings cancel — a true trade, produced for free by applying one symmetric per-contact rule
twice, not by a second arbitration pass. This is consistent with the Non-Negotiable Rules this plan is
written under: it creates no infinite stun (hitstun is short, fixed, and every hit that causes it was
itself avoidable — blockable, parryable, or duckable by spacing), it never removes agency without a
clearly telegraphed, proportionally-earned opportunity to avoid it (the telegraph is the same Windup
every attack already authors), and it makes "everything is defendable" concretely true for the *attack*
side of an exchange, not only the *damage* side: a well-timed swing is now itself a counterplay tool
against a mid-combo opponent, not just a damage race running in parallel.

### Kill attribution — a small, needed seam outside this plan's own three layers

`PlayerDeathSystem.lua` (alive, boots today, subscribes to nothing about damage) confirms every death
through one `Humanoid.Died` handler and always fires `GameplayEvents.FirePlayerKilled(victim, nil)` —
`killer` is hardcoded `nil` because, per that module's own header, *"with no combat/PvP system, there
is no notion of who dealt the fatal blow."* Once `DamageSystem` calls `Humanoid:TakeDamage`, that
sentence stops being true, and nothing today closes the gap.

This plan does not implement the fix — it isn't one of the three layers in scope — but names the seam
so it isn't rediscovered as a surprise: `DamageSystem` should fire a small, new `GameplayEvents` signal
(e.g. `FireDamageAttributed(victim, attacker, amount)`) immediately before applying damage that could be
lethal, and `PlayerDeathSystem` should remember the most recent attributed source per victim
(bounded, `PlayerRemoving`-cleaned, the same shape every other per-player table in this codebase
already uses) to supply as `killer` when `Humanoid.Died` actually fires moments later. This keeps
"who confirms a death" singular in `PlayerDeathSystem` (no second `FirePlayerKilled` caller racing it)
and matches `GameplayEvents`' own stated philosophy exactly: *"the correct change is a new field on
this file's payload... it carries facts; every consumer decides its own response."* Flagged, not built.

---

## Client responsiveness policy

### The no-prediction stance is inherited, deliberately, and the client still feels fast

`HitboxEngine`'s header states this as an explicit architectural choice: *"SERVER-AUTHORITATIVE, WITH
NO CLIENT PREDICTION... There is no rollback, no client mirror, no remote in this file, and the deleted
PredictionMirror/CombatClient pair is not being rebuilt."* This plan inherits that stance for the same
reason `DefenseSystem` already did — a codebase that deliberately tore out `PredictionMirror` once
should not quietly reintroduce it one layer up. **No client mirror of health, posture, combo stage, or
hit outcome is built.** The HUD reads server-pushed state only.

This is not a reversal of the policy, and the distinction matters: `DefenseClient.lua` (per the
parry/block plan's own description) already establishes the actual shape of "responsive without
prediction" in this codebase — it plays its own block-raise presentation immediately on press, and the
server's `Defense_StateChanged` event is *"the correction and the confirmation,"* never a rollback
target. Nothing about that press is ever undone; the server either agrees (nothing further happens) or
disagrees (a follow-up event corrects the *presentation*, never a *hit outcome* the client had already
claimed). The attack layer adopts the identical shape:

1. **Local optimistic windup, unconditionally, on press.** The instant `Constants.Keybinds`' bound key
   fires (unchanged — `BasicAttack`/`HeavyAttack`/hotbar slots are all still live default bindings),
   `AttackInputClient` plays the windup animation/audio/VFX immediately, using its own best local guess
   at which stage is next (mirroring whatever `SwingSequencer` state the client can locally infer from
   its last `Attack_Started` confirmation). This has no fairness stakes — worst case, an animation
   plays and nothing follows, which is cosmetically recoverable and never a hit/miss decision made
   client-side.
2. **The request fires immediately, not gated on animation completion** — same as
   `TestAttackHarnessClient`'s own `remote:FireServer()` on press.
3. **Server-side input buffering**, reviving the *shape* of the dead `bufferedAttack` field (not its
   code — that field lived on a type nothing constructs anymore) as explicit prior art. A request that
   arrives while `DefenseSystem.CanAttack`/`DamageSystem.CanAttack`/`SwingSequencer` would refuse it
   only because the gate hasn't cleared yet (still in recovery/cooldown/hitstun by a small margin) is
   remembered for `DamageConstants.AttackInputBufferSeconds` and thrown automatically the instant the
   gate opens, **re-validated at flush time** — a player who gets parried mid-buffer must not have the
   buffered swing fire anyway. Note: the old `AttackInputBufferSeconds` constant no longer exists
   anywhere in `Constants.lua` (confirmed by grep) — this is a genuinely new value to author, not a
   resurrection of a live one, though the *name* is kept for continuity with the prior art it's citing.
4. **`Attack_Started`, non-optimistic, attacker-only**, the moment the server actually accepts —
   mirrors the dead `AttackStartedPayload` field-for-field (see "The attack layer" above). This is what
   corrects a wrong local guess (a mistimed combo-stage read, say) without ever needing to undo a
   *hit*.
5. **`Combat_Feedback`, minimal round trip, both participants.** The instant `DamageSystem` resolves a
   contact — the same `Heartbeat` pass `DefenseSystem` resolved it in, so the added latency beyond the
   hit's own `SampleTime` is one frame, the practical floor without inventing prediction — it fires one
   event carrying `Kind`/`DamageAmount`/`PostureAmount`/`DebugName`/`ContactPosition` to the attacker
   (hit-flash, hitstop, a damage number — "I landed that") and to the defender (hit-reaction animation,
   camera shake — "I got hit"). This mirrors the dead `CombatFeedbackPayload` and
   `TestAttackHarness.relayOutcome`'s already-proven shape almost exactly. Hitstop itself
   (`Client/FX/HitStop.lua`, already present in the tree) is purely client-local once triggered — no
   further round trip needed.
6. **`Vitals_Updated`, change-driven, owner-only.** Health/posture/combo-stage pushed to the HUD only
   on an actual change, not polled — the same suppression discipline `DefenseSystem.publishState`
   already uses for the `DefenseState` Attribute.

### RemoteEvent shape and call frequency

| Remote | Direction | Frequency | Payload |
|---|---|---|---|
| `Attack_Request` | client → server | ≤ once per press + buffer flush | action selector only, no target/position/timestamp |
| `Attack_Started` | server → attacker | once per accepted throw | mirrors dead `AttackStartedPayload` |
| `Combat_Feedback` | server → attacker & defender | once per resolved contact | mirrors dead `CombatFeedbackPayload` |
| `Vitals_Updated` | server → owner | on change only | health/posture/comboStage |

`Attack_Request` gets its own `RateLimiter` bucket, sized against `DefenseConstants.Network.
MaxCallsPerSecondPerPlayer` (12) as the established analog — proposed ~10/sec, generous enough that no
legitimate combo string is ever throttled (even a fast three-hit string is nowhere near 10 presses/sec)
while bounding a spamming client the same way every other public remote in this codebase already does.

Worth flagging as an implementation-time simplification, not mandated here: `Combat_Feedback` and
`DefenseSystem`'s own `Defense_StateChanged` cover overlapping ground (both are "something happened to
you or because of you, tell the client"), and the 2026-08 architecture audit's own performance section
already recommended merging the old `VitalsUpdated`/`FeedbackEvent` pair for the identical reason
(§4, item 2.6). A single consolidated combat-feedback channel is a legitimate follow-up once both
systems are live and their payloads are seen side by side — not assumed here, since `DefenseSystem`'s
remote contract is already shipped and changing it is out of this plan's own scope.

---

## Realistic QOL, included

- A blocked hit gives the attacker no combo-escalation credit and no window extension — blocking
  reads as a real answer, not a discount.
- A parry's own stagger already outlasts the attacker's combo window with no special-cased reset.
- Trading hits is a real, legible outcome: both combatants pay for it symmetrically, with no arbitrary
  "who wins" rule layered on top of the damage numbers themselves.
- A well-timed counter-hit can stop an opponent's combo outright, independent of blocking or parrying —
  spacing and timing are themselves counterplay, not just damage-race inputs.
- The attacker gets the same "I landed that" feedback loop the parry/block layer already gives
  defenders, on the same one-frame-after-`SampleTime` budget.
- Local windup presentation means input never feels like it waits on a round trip, without
  reintroducing any of the reconciliation surface the engine was built to avoid.

## Explicitly out of scope

Ragdoll/knockback physics application (this plan resolves *that* a hit knocks back and by how much, via
`DamageResult`, but not the physics rig that applies it — that's the same category of work
`RagdollController.lua` used to own and nothing here rebuilds it), animation authoring/timeline
scheduling beyond the existing `AnimationTimeline` machinery, VFX/SFX/camera-shake implementation
(consumed by the client from `Combat_Feedback`, not designed here), bot/dummy AI decision-making (both
register with `HitboxEngine`/`DefenseSystem`/`DamageSystem` exactly like a player and need no special
casing in any of the three layers — matching every other module's own domain-agnostic registration
shape — but *deciding* when a bot throws an attack is a different system's job), the kill-attribution
fix itself (named above, not implemented), the Posture-vs-Guard resource question's final answer (named
above as an open question), and reconnecting the Move Creation System's editor UI to anything beyond
the one new projection function this plan proposes.

## Verification

- `SwingSequencer.spec.lua` — throw-based advancement regardless of outcome, window expiry resetting
  to stage 1, no dependency on anything outcome-related.
- `AttackCatalog.spec.lua` — `MoveRegistryManager` precedence over `DefaultMoveRegistry`, the
  five-dropped-shapes fallback-to-`Box` behavior and its logged warning, the flat-scaling-profile
  default, a missing `MoveId` returning `nil` rather than a default attack.
- `VitalsMeter.spec.lua` — pure math for posture drain/regen (mirroring `GuardMeter.spec.lua`'s own
  shape), `PostureBroken` triggering at exactly zero (not merely below), health delegating to
  `Humanoid:TakeDamage` with no shadow state.
- `ComboEscalation.spec.lua` — advances only on Clean/Backstab/GuardBroken, never on Blocked, window
  expiry dropping stage back to 1 with no special-cased reset path.
- `DamageResolver.spec.lua` — pure, table-driven: every `OutcomeKind` from a synthetic
  `DefenseOutcome`, the Blocked-still-drains-some-posture rule, Parried/Trade applying zero damage.
- `DamageSystem.spec.lua` — synthetic rigs driven through the real `HitboxEngine`+`DefenseSystem`
  chain (the same "build dummies with `Instance.new`, no `DummyCombat`/`TrainingBotSystem`" shape
  `DefenseSystem.spec.lua` already established): a Clean hit against a mid-swing defender cancels
  their swing; two combatants trading Clean hits in one batch both get hitstunned and both cancel,
  symmetrically, with neither favored; a Parried attacker's `ComboEscalation` window has visibly
  lapsed by the time their stagger ends, asserted at the boundary the way `DefenseSystem.spec.lua`
  asserts its own one-frame residual bound rather than merely its absence.
- `AttackRequestSystem.spec.lua` — a request arriving mid-refusal is buffered and flushed once the
  gate clears; a buffered request that becomes illegal before flush (parried mid-buffer) is dropped,
  not forced through; the rate limiter bucket is independent of `DefenseSystem`'s own.
- The whole suite plus `selene`/`stylua`, and a BOM scan on new files — the same standing gotcha
  `ParkourConstants` has already burned this codebase on once.

## Open questions

1. **Does Posture survive as a second resource distinct from `Guard`, or is `Guard` the intended single
   defense pool going forward?** See "Posture — a real open question, not a given." This is a genuine
   feel/scope call the repo owner should make explicitly rather than one this plan should assume by
   building it.
2. **`HitstunSeconds`'s actual value**, and its relationship to `WindupSeconds` across the real
   (not-yet-authored) move set once one exists — the ~0.4–0.5s figure above borrows only the order of
   magnitude from the old `HitStunDuration = 0.6`, not a re-derivation against real frame data, since
   no real attacks exist yet to derive it against.
3. **`ComboWindowSeconds`'s actual value**, constrained only by "strictly less than whatever
   `Stagger.DurationSeconds` ends up being" (itself still open per the parry/block plan's own item 2).
4. **Blocked hits: zero escalation credit (this plan's recommendation) or reduced credit** (the
   parry/block plan's own tentative lean)? Both are internally consistent; they read differently to a
   player and should be picked deliberately, not defaulted.
5. **Is the Move Creation System bridge (Option B) worth its reconnection cost right now**, or should
   the attack layer ship against a smaller, hand-authored move set first (Option A, revisited later)
   purely to unblock combat sooner, with the bridge landing as a fast-follow once the Move Editor UI's
   own test coverage can be re-verified against the new engine end to end? Recommended: B, for the
   reasons in "The Move Creation System bridge" — but it is the single largest scope decision in this
   plan and deserves an explicit yes.
6. **Should `Attack_Request` accept a client-reported "holding a modifier" hint** (the old
   `holdingJump` pattern `CombatTypes.lua` documents for the deleted standalone air attack) for a future
   airborne/charge variant, the same trust tier that design already established (bounded payoff even if
   the client lies) — not needed for this plan's own scope, but worth deciding now whether the request
   payload should be designed with room for it before the shape ships and callers depend on it staying
   narrow.
