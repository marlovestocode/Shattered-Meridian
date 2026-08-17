# Parry & Block System — Implementation Plan

Status: proposed, not built. Written against `progression-spine` after the standalone
`HitboxEngine` landed.

## Revision 2

Every factual claim in revision 1 was checked against the branch and held, including the
`HitReport.SampleTime` / `CancelAttack` / `AttackStateMachine` seams and the orphaned
`Constants.Combat` fields. What changed:

- **Resolution is now two-pass, and window membership is evaluated at each report's `SampleTime`**
  rather than at frame end. Revision 1's single end-of-frame pass would have misclassified hits that
  straddle a window boundary within one frame. See *Trading*.
- **`ParryWindows.Register` added** as an explicit pre-asset window source, since no parry or block
  animation exists in `Constants.AnimationIds` at all. Markers still win; production stays
  fail-closed. See *Failing closed*.
- **`HitboxEngine.CancelAttack` needs a `now` parameter.** It is the engine's only entry point that
  reads `os.clock()`, against that module's own stated rule. See *Integration seams*.
- **The 1.5s stagger is flagged against a derived upper bound of ~0.75s** from the previous design.
  See *The parried attacker's punish*.
- Release-during-window, recovery fallback, trade guard handling, and Heartbeat ordering were all
  underspecified and are now pinned down.

## Context

The hitbox engine reports contacts and deliberately refuses to say what a contact *means*
(`Server/Combat/HitboxEngine/HitboxEngine.lua`). This system is the first consumer of that signal:
it takes a `HitReport` and decides what kind of hit it was — clean, blocked, parried, traded,
guard-broken, backstab — and then hands that verdict on to whatever applies damage later.

Three layers, each ignorant of the one above it:

```
HitboxEngine        where the volume is, who is inside it        (built)
DefenseSystem       what kind of hit that was                    (this plan)
CombatSystem        how much it hurts, what it does to you       (future)
```

That middle layer is the whole point of the shape. Damage numbers, health, posture pools,
knockback, animations of getting hit — none of it appears in this plan. `DefenseSystem` emits a
`DefenseOutcome` and stops. When the real combat system is built it subscribes to that outcome the
same way this subscribes to `OnHit`, and neither has to be rewritten to accommodate the other.

### What already exists, and what it costs us

`Constants.Combat` survived the combat teardown and still carries the **previous** parry design:
`ParryWindowSeconds = 0.35`, `ParryCooldownSeconds`, `ParryPunishPostureDamage`,
`ParryPingCompensationMaxSeconds`, and a long comment block titled "THE PARRIED ATTACKER'S OPEN
GUARD". Every consumer of those fields was deleted, so they are orphaned config today. Two of them
matter to this plan:

- `ParryWindowSeconds = 0.35` is exactly the hardcoded window this plan is required to remove. It
  gets retired, not reused.
- `ParryPingCompensationMaxSeconds = 0.12` is worth keeping (see "Ping compensation" below). It is
  a *latency correction*, not a window length, so it survives the "no hardcoded parry timing" rule.

`Constants.Keybinds.Defaults.Block` is already `F`, already documented as *"Block and Parry share
this one input — a press opens a short parry window, holding past it is a plain block."* That is
precisely the input model requested here, so the keybind layer needs no changes at all.

## The timing authority — no hardcoded windows

This is the crux of the request and the part most likely to be got wrong, so it gets the long
explanation.

### Where the numbers come from

The parry window is defined by markers authored into the animation asset itself. An animator places
`ParryStart` and `ParryClose` markers on the parry clip's keyframes; those two times
*are* the window. Retiming the parry means retiming the animation and nothing else — no constant to
find, no second place to keep in sync, and the visual and the mechanic cannot drift apart because
they are the same data.

Three markers, all optional except the first two:

| Marker | Meaning |
| --- | --- |
| `ParryStart` | Parry becomes live |
| `ParryClose` | Parry stops being live; block becomes available from here |
| `ParryRecoveryEnd` | Whiffed-parry lockout ends (falls back to `DefenseConstants.Parry.RecoverySeconds` if absent) |

### Why NOT `GetMarkerReachedSignal` on the server

The obvious reading of "use the animation's attached events" is to play the track and listen. That
is the right mechanism on the **client**, and the wrong one for the **authority**, for three
reasons:

1. The server would have to play the track on the character's `Animator` to hear its markers, which
   means the authoritative window's start depends on animation replication rather than on the input
   arriving.
2. If the track is interrupted — a hit reaction, a respawn, the parkour framework taking the body —
   `ParryClose` **silently never fires**. A window that opens and never closes is a permanent
   parry, and it fails in the direction that rewards the bug.
3. It makes the window untestable without playing real animations in real time.

`Constants.Run.Footsteps` already carries a note from an earlier decision to avoid marker-driven
timing for exactly this class of reason: *"only as reliable as the authored markers in whatever clip
is currently playing."* That caution is right and this plan has to answer it rather than ignore it.

### The approach: read the asset, don't listen to the track

`KeyframeSequenceProvider:GetKeyframeSequenceAsync(animationId)` returns the authored
`KeyframeSequence` without playing anything. Walking its `Keyframe` children for `Marker`
descendants yields the exact authored marker times. So:

- **Server**: extracts marker times once per animation id, caches them, and runs its own
  authoritative timer from those numbers. Same numbers the animator authored, none of the
  fragility of a live track.
- **Client**: plays the clip and uses the live `GetMarkerReachedSignal` purely for presentation —
  the flash, the sound, the stance change. If a client marker disagrees with the server, the server
  wins and the client is merely a frame or two of polish out.

Both derive from one asset, so they agree by construction.

### Failing closed

If an animation has no `ParryStart`/`ParryClose` pair — the animator forgot, the asset
failed to load, the id is wrong — `ParryWindows.Get(id)` returns `nil` and **the parry is not
armed**. The input still produces a plain block; it just never opens a parry window.

It must not fall back to a default window. A default is the hardcoded value this plan exists to
remove, and substituting one silently turns "someone forgot a marker" into "this move's parry has
been subtly wrong for a month."

To make that failure loud instead of invisible, `ParryWindows.ValidateAll()` runs at boot over every
registered defense animation and warns per missing marker. A missing window is then a startup
warning, not a mid-fight mystery.

#### The registration path, and why it is not a default

`Constants.AnimationIds` contains **no parry or block clip at all** — not unmarked clips, none. So
under strict fail-closed, building this system yields one where parry can never fire, and the
failure surfaces as a boot warning rather than as anything a playtest would read as "parry is
missing." That is too quiet for a mechanic this central.

So windows have two sources, in strict precedence:

1. **Authored markers** on the animation asset. Always win when present.
2. **`ParryWindows.Register(animationId, { Open, Close, RecoveryEnd? })`** — an explicit, in-code
   declaration. This is the pre-asset path, and the injection point the specs already needed.

There is still no third case. An id with neither markers nor a registration returns `nil` and the
parry is not armed, exactly as above. A registration is not a default: it is per-id, written by
hand, and visible in a grep — the three properties the forbidden fallback lacks.

`ValidateAll()` additionally warns on any registration **shadowed** by authored markers, so once the
real clips land the now-dead registrations are reported rather than silently ignored. That is what
keeps the animation the authority in the end state without blocking work until it arrives.

A Studio-only `ParryWindows.Override(animationId, window)` exists for live tuning in the dev menu.
It is gated on `RunService:IsStudio()` so it cannot ship as an accidental authority.

`GetKeyframeSequenceAsync` yields and is rate-limited, so extraction is: cache-first, one in-flight
request per id (concurrent callers await the same request), bounded retry with backoff, and a
permanent negative cache entry after the last retry so a bad id cannot be re-requested forever.

### Ping compensation

The server opens its window when the request *arrives*, which is already ~one-way latency after the
player pressed. The old design's fix is worth keeping: add `min(playerPing, cap)` to the window so a
high-ping player gets back roughly what their connection ate, capped so a spoofed ping cannot buy a
permanent parry. Bots and dummies get none, having no latency.

This adds to a marker-derived window rather than defining one, which is why it stays.

**Compensation extends the window without delaying the block.** `ParryClose` is doing two jobs
— it ends the parry and it begins `Blocking` — and naively adding ping to it would push a high-ping
player's guard *up later*, punishing them for the latency this is supposed to refund. So the single
marker yields two derived times: a parry-classification end at `Close + min(ping, cap)`, and a
`Blocking` transition at `Close` unmodified. The compensation is then strictly a refund, never a
cost, which is the only shape in which it is defensible at all.

## Where it lives

```
src/ReplicatedStorage/Shared/Defense/
    DefenseTypes.lua          -- DefenseOutcome, DefenseState, ParryWindow, guard config
    DefenseConstants.lua      -- non-timing tunables (arc, guard meter, stagger length)
    ParryWindows.lua          -- marker extraction + cache + Register/Override; injectable extractor

src/ServerScriptService/Server/Combat/Defense/
    DefenseStateMachine.lua   -- per-combatant Neutral/Parry/Block/Stagger/GuardBroken FSM
    GuardMeter.lua            -- block drain, regen, guard break
    OutcomeResolver.lua       -- pure: (HitReport, attacker state, defender state) -> outcome
    DefenseSystem.lua         -- public module; owns the OnHit subscription and the remotes

src/StarterPlayer/StarterPlayerScripts/Client/Defense/
    DefenseClient.lua         -- input, local animation playback, live marker presentation

src/Tests/Combat/Defense/
    ParryWindows.spec.lua
    DefenseStateMachine.spec.lua
    OutcomeResolver.spec.lua
    DefenseSystem.spec.lua
```

`OutcomeResolver` is split out and kept **pure** on purpose — no Instances, no clock, no services.
Every interesting rule in this system (is this a parry, is it a trade, did it come from behind, does
the guard hold) is a decision about a few values, and a pure resolver means all of it is testable
without a rig, the same discipline that made `HitboxGeometry` worth separating from `HitboxEngine`.

## The defense state machine

One instance per registered combatant, structurally mirroring `AttackStateMachine` — caller-supplied
clock, transitions timed to when they were *due* rather than when they were noticed, bounded
chaining so a zero-length phase doesn't cost a frame.

```
Neutral ──press──> ParryWindow ──Close marker──> Blocking ──release──> Neutral
                        │                            │
                        │ (window closed, no hit,    │ guard meter empty
                        │  input released)           ▼
                        └──────> ParryRecovery    GuardBroken ──> Neutral
                                     │
Staggered (entered from any state when THIS combatant's attack is parried)
   • cannot attack      • cannot parry      • CAN block      • 1.5s
```

- **ParryWindow** — live from `ParryStart` to `ParryClose`. A hit resolved inside it is a
  parry.
- **Blocking** — entered at `ParryClose` if the input is still held. Directional (below).
- **ParryRecovery** — entered when the window closes with no hit *and* the input was released: a
  whiffed parry tap. Cannot parry again until it ends. This is the anti-spam gate; without it,
  mashing the parry key is free and the read-based combat the parry exists to create collapses into
  a reflex check. Its length comes from the `ParryRecoveryEnd` marker.

**Releasing during the window does not cancel it.** Revision 1 left this open, and all three
readings are reachable from its text. The rule is: once `ParryWindow` is entered, it runs to
`ParryClose` regardless of the input, and release only decides where `Close` leads — `Blocking`
if still held, `ParryRecovery` if not. A parry is a committed read, not something retractable, and
the alternative hands out a free arm-and-disarm: tap, keep a live window, and stay free to act
inside it.

**`ParryRecoveryEnd` fallback.** Revision 1 defaulted it to the clip's own length, which has no value
when extraction failed outright (no `KeyframeSequence`, so no length either) or when a registration
omits it. It falls back to `DefenseConstants.ParryRecoverySeconds`. That is legitimate under this
plan's own rule and for its own stated reason: a recovery is a *punish length*, a balance decision
with no animation defining it — the same argument the 1.5s stagger is granted below. It is not a
parry window, and nothing about the timing authority is weakened by giving it a constant.
- **Staggered** — the parry punish. Detailed below.
- **GuardBroken** — the guard meter emptied while blocking. A real opening; cannot block until it
  ends.

## Outcome resolution

`OutcomeResolver.Resolve(report, attackerState, defenderState, facing) -> DefenseOutcome`

```lua
export type OutcomeKind =
      "Clean"        -- nothing stopped it
    | "Blocked"      -- inside the block arc, guard held
    | "GuardBroken"  -- inside the arc, guard meter emptied on this hit
    | "Backstab"     -- blocking, but struck from the rear hemisphere
    | "Parried"      -- landed inside the defender's live parry window
    | "Trade"        -- both combatants parried each other in the same resolution batch
```

The outcome carries the originating `HitReport`, the two combatants, the bearing the hit arrived
from, and the guard meter's state after resolution — everything a damage layer needs, with none of
its decisions pre-made.

### Trading

The engine timestamps every hit with `SampleTime`, accurate to a substep. `DefenseSystem` therefore
does **not** apply hits as they arrive: it buffers each frame's reports and arbitrates the batch at
the end of the frame. Two combatants who parried each other within the same batch produce a single
`Trade` — neither is staggered, and both are pushed apart.

That gives simultaneity a definition that costs no new tuning value: the quantum is one engine
substep, which is already the finest distinction the engine can make. A trade window invented on top
of it would be a second, arbitrary number that could disagree with the first.

The same batching gives **attack trades** for free — two clean hits landing in one batch resolve
together, so neither attacker gets a free combo out of a mutual exchange. That is a realistic
outcome the old per-hit-immediately model could not express.

### Two passes, not one

Revision 1 said the batch is *resolved* at frame end. That is wrong for classification and right only
for arbitration, and the difference is a real misclassification bug.

`HitboxEngine.Step` subdivides a frame into up to `MaxSubstepsPerFrame` (8) substeps of
`MinSubstepSeconds` (1/120) and fires `OnHit` from inside that loop. So one frame can deliver hits
spanning tens of milliseconds of engine time — comfortably wider than a parry window. Classifying the
whole batch against the defender's state *at frame end* would let a hit that landed before
`ParryStart` be parried, and a hit that landed after `Close` be parried, both silently.

So:

- **Pass 1 — classify, eagerly, inside `OnHit`.** Each report is evaluated against the defender's
  state **as of that report's `SampleTime`**, producing a provisional outcome. Nothing is applied:
  no cancel, no guard drain, no stagger. This is why `DefenseStateMachine` must be able to answer
  "what state were you in at time *t*", not merely "what state are you in" — it already keeps
  `enteredAt` per state for exactly this, mirroring `AttackStateMachine`.
- **Pass 2 — arbitrate and apply, at frame end.** Detect mutual parries across the batch, collapse
  them to `Trade`, then apply everything and emit through `OnResolved`.

"The window consumes on the first contact" therefore means **lowest `SampleTime`**, not arrival
order. Ties within a single substep are broken by the engine's own iteration order, which is
deterministic but not meaningful; a tie is a genuine simultaneous hit and both are resolved against
the same window, with only the first consuming it.

### The one-frame residual, stated rather than hidden

Because cancels apply in pass 2, a parried attacker's swing keeps sampling for the remainder of the
frame it was parried in, and can land a contact after the parry that killed it. This is bounded at
one frame and is the same bound the engine already accepts elsewhere — its substep loop deliberately
defers a callback-started follow-up swing to the next frame for the same reason.

The alternative is cancelling eagerly in pass 1, which reintroduces the ordering problem trades exist
to solve: whoever's report arrived first would cancel the other before the trade could be seen. The
residual is the cheaper of the two, but it should be a known cost rather than a surprise in a
playtest, and `DefenseSystem.spec` asserts the bound rather than the absence.

`CancelAttack` is nonetheless issued with the parry's `SampleTime`, not the frame-end clock, so the
attacker's own machine records the interruption at the moment it actually happened. That requires the
engine change in *Integration seams*.

## Directional blocking

At resolution time, compute the horizontal bearing from the **defender's** live `LookVector` to the
attacker's root position. Within `BlockArcDegrees / 2` the block applies; outside it:

- **rear hemisphere** → `Backstab`. Blocking does nothing, and it is a punish worth having.
- **flanks, outside the arc but not behind** → `Clean`. Ordinary unblocked damage.

Facing, not movement direction — shift lock decouples the two, and the question here is genuinely
"which way is this player looking," which is what facing means. (This is the same distinction the
parkour states had to make; a motion-derived answer would let a backpedalling player block things
behind them.)

`BlockArcDegrees` is a tuning constant and stays one: it is a geometry value, not a parry timing
value, and there is no animation that could authoritatively define it.

## The parried attacker's punish

Per spec: **1.5 seconds**, during which they cannot attack and cannot parry, but *can* block.

Movement is slowed, not frozen. A parry that removes control entirely reads as a cutscene, and the
brief says explicitly not to make it unfair.

The 1.5s is a hardcoded number — deliberately, and it is not the kind the brief forbids. The rule is
"no hardcoded *parry timing window* values," because the window is what must track the animation.
A punish duration is a balance decision with no animation that defines it. It lives in
`DefenseConstants` with the intent recorded, and the stagger animation should be authored to match
it so the visual and the lockout end together.

### A conflict with the previous design, flagged deliberately

`Constants.Combat`'s "THE PARRIED ATTACKER'S OPEN GUARD" comment records that the old system made a
parried attacker **unable to block at all** for 0.60s, and explains why: the punish had been
measured and found to be nothing, precisely *because* block was exempt from the stun. Its numbers:
the earliest a parried attacker could press block was 0.36s after a parried Basic1 and 0.77s after a
Heavy1, so parrying a basic attack "bought nothing a human could act inside."

This plan's spec — parried attackers can block — re-opens that exact hole. It is your call and the
plan implements it as specified, but it should be implemented with a counterweight rather than
naively, or the parry stops being worth going for:

**Blocking while staggered is allowed, but it is not free.** During `Staggered`:

- guard meter does **not** regenerate,
- blocked hits drain guard at an increased rate,
- mitigation is reduced from its normal value.

So a parried attacker who turtles through the punish spends their entire guard doing it and comes
out the far side one hit from a guard break. They kept the option, and it still cost them the
exchange. That satisfies "can block" and "not overly unfair" without reverting to a punish the old
system already measured as hollow.

### 1.5s exceeds the previous design's derived upper bound

This needs stating before it is built, because the number is not arbitrary in either direction.

`Constants.Combat.GuardOpenSeconds = 0.6` carries a derivation, not a guess. It was sized to cover
reaction plus one-way latency plus the slowest weapon's own windup (`Primary Basic1`,
`WindupSeconds = 0.31`, still live at `Constants.lua:3430`) so that the parrier gets **exactly one
guaranteed follow-up**. And it records a *hard upper bound*: past roughly **0.75s**, a Secondary
user's second swing also lands inside the window — which its own comment calls "a combo handed out
for one read rather than a conversion."

**1.5s is double that bound.** The brief specifies it, so it stands as your call and the plan
implements it, but the consequence should be chosen rather than inherited: at 1.5s a parry converts
into a full combo, not a single punish, which is a materially different game from the one the
previous tuning pass was aiming at.

It also compounds with the counterweight above. A staggered attacker who *can* block is now blocking
through a window 2.5× longer at increased guard drain and no regeneration — so the guard cost of
turtling through a stagger needs to be tuned against 1.5s, not against 0.6s, or it stops being a
counterweight and becomes a guaranteed guard break.

Three ways forward, in the order I'd recommend them:

1. **0.6–0.75s**, adopting the derived bound, with the counterweight as written.
2. **1.5s with the combo accepted**, and the stagger's guard drain retuned down accordingly, since
   the punish no longer needs the guard cost to have teeth.
3. **1.5s of "cannot attack, cannot parry" but only ~0.6s of degraded blocking**, splitting the
   visual punish from the mechanical one. Longest to tune, most likely to feel right.

Worth re-measuring against real frame data once attacks exist either way.

## The guard meter

Blocking is not free either, for the same reason: a block with no cost is a turtle strategy, and a
turtle strategy is what makes defensive systems boring rather than tense.

- Each blocked hit drains guard, scaled by the attack's `PowerLevel` (already on the `HitReport`).
- Guard regenerates when not blocking and not recently hit.
- Emptying it → `GuardBroken`, a real opening.
- A successful **parry** restores guard. That is the incentive gradient the whole system is built
  around: parrying is better than blocking, blocking is better than eating it, and the reward for
  the harder option is the resource that lets you keep taking the easier one.
- A **trade** withholds that restore from both sides. Revision 1 said a trade "resets both guards to
  a neutral value," which is exploitable in the obvious way: two players with depleted guards could
  parry each other on purpose to refill. A trade should be neutral, and the only non-exploitable
  neutral is to grant nothing — neither the restore nor a drain. Mutual parries then cost a swing
  each and change no resource, which is what a trade means.

## Integration seams

- `DefenseSystem.Init()` subscribes to `HitboxEngine.OnHit` and owns its own `Heartbeat` for the
  state machines, the same self-driving shape the engine uses (with a `Step(dt, now)` underneath it
  so the specs can drive a synthetic clock).
- **That Heartbeat must be connected after the engine's, and the ordering is load-bearing.** Roblox
  fires Heartbeat connections in connection order, so if `DefenseSystem.Init()` runs before
  `HitboxEngine.Init()`, pass 2 executes *before* the substeps that fill its buffer and every batch
  resolves a frame late — invisibly, and only on some boot orders. `Main.server.lua` already treats
  ordering as a correctness property in several places and documents it; this is one more. `Init()`
  additionally asserts the engine is already started rather than trusting the comment.
- On `Parried`, it calls `HitboxEngine.CancelAttack(attackerId, "Parried", sampleTime)`.
- **This requires a one-line engine change.** `CancelAttack` currently calls
  `Machine:Interrupt(reason, os.clock())` — it is the engine's *only* entry point that reads the wall
  clock, and it contradicts `AttackStateMachine`'s own stated rule: *"TIME COMES FROM THE CALLER on
  every entry point, never from `os.clock()` here."* It has no callers yet, so adding a `now`
  parameter is free today and impossible to do quietly later. Without it, the parried-attacker path
  is the one path in this system that cannot be driven on a synthetic clock — which is exactly the
  path `DefenseSystem.spec` most needs to drive.
  The cancel is dispatched in pass 2 but timed from the parry's `SampleTime`, so the attacker's
  machine records the interruption at the substep it actually occurred.
- Everything else about the cancel holds as written: `Interrupt` chains through `Interrupted` to
  `Idle` and the engine's exit path clears `RootControlLocked` via its own `setMovementLock`. No
  other engine change is needed.
- **Attack gating is the defense layer's job, not the engine's.** `DefenseSystem.CanAttack(id)`
  returns `(boolean, reason)`, and the input layer consults it before `HitboxEngine.RequestAttack`.
  The engine stays ignorant of stagger, which is what keeps it standalone.
  Note there is **no attack input layer on this branch** — it went with `CombatClient.lua`. So
  `CanAttack` ships correct and unconsumed, and nothing enforces stagger's no-attack rule until that
  layer is rebuilt. Worth knowing so it is not mistaken for wired.
- A `DefenseState` string Attribute on the Humanoid mirrors the current state for the HUD and for
  debug tooling. `RootControlLocked` is additionally set during `Staggered` and `GuardBroken` only,
  so parkour hands the body over for those and only those.
- `DefenseSystem.OnResolved(callback)` is the output signal the future damage layer subscribes to.
  Nothing in this system applies damage.
- **Retire** the superseded `Constants.Combat` fields (`ParryWindowSeconds`, `ParryCooldownSeconds`,
  `ParryPunishPostureDamage`) rather than leaving them as orphaned config that reads as live.
  `ParryPingCompensationMaxSeconds` moves to `DefenseConstants`.
- The retirement sweep is wider than revision 1 listed. Also in scope:
  - `Types.lua` carries the old system's remote payloads — `BlockStartedPayload.ParryStarted`
    (~`Types.lua:527`) and a reference around `Types.lua:391`. They are orphaned and read as live.
  - `Constants.PresetWeights` (~`Constants.lua:382`) cites `ParryWindowSeconds` in a comment that
    outlives the field.
  - `GuardOpenSeconds` and `GuardResetSeconds` are *this system's* concepts now, not the deleted
    one's. They should move to `DefenseConstants` with their derivations intact rather than be
    retired — `GuardOpenSeconds` is the 0.6s discussed above, and `GuardResetSeconds` (0.3s, charged
    on release) is an anti-turtle cost this plan otherwise has no answer for.
  Leaving a comment that names a deleted constant is the same trap as leaving the constant.

## Realistic QOL, included

- Hit from behind while blocking lands clean, with a backstab punish.
- Blocking slows movement.
- Blocking has a raise time — the block is not live until `ParryClose`, which is authored, so
  you cannot block instantly out of a whiffed attack.
- A whiffed parry has a real recovery, so mashing is punished.
- Parrying one attack does not parry every simultaneous attack: the window consumes on the contact
  with the lowest `SampleTime` in a batch, so being surrounded is genuinely dangerous.
- On a successful parry, the defender snaps to face the attacker — a parry that leaves you facing
  the wrong way feels broken even when it worked.
- Guard regenerates out of combat so a fight does not start with a deficit from the last one.
- Attack trades resolve mutually; neither side gets a free combo.

## Explicitly out of scope

Damage numbers, health and posture pools and their application, knockback and ragdoll, hit
reactions, VFX/SFX/camera feedback, the attack move set itself, bot AI defense presets (the
`Constants.Combat` bot `Parry`/`Block` weight tables are orphaned along with the deleted
`TrainingBotSystem` and should be revisited with that system, not this one), and any HUD work beyond
publishing the `DefenseState` Attribute.

## Verification

- `ParryWindows.spec.lua` — marker extraction against `KeyframeSequence`s built in-place with
  `Instance.new`, so it needs no published asset: correct times parsed, missing markers return
  `nil`, malformed markers rejected, the cache serves a second call without re-extracting, and a
  failed extraction is negatively cached rather than retried forever. Plus the precedence rules:
  a registration serves an id with no markers, authored markers beat a registration, `ValidateAll`
  warns on a shadowed registration, and an id with neither still returns `nil`.
- `DefenseStateMachine.spec.lua` — synthetic clock, no rig: the full state walk, the whiff-recovery
  branch, stagger's can-block-cannot-attack rule, release-during-window running to `Close` anyway,
  and phase boundaries landing on their due times rather than drifting under a late `Step`. Also the
  historical query pass 1 depends on — "what state were you in at time *t*" — including a *t* inside
  a window the machine has already left.
- `OutcomeResolver.spec.lua` — pure, table-driven: every `OutcomeKind` from a synthetic report,
  every arc boundary, the guard-break edge, and the trade case.
- `DefenseSystem.spec.lua` — synthetic rigs in the run-in-roblox place (built with `Instance.new`,
  the same way `HitboxEngine.spec.lua` already builds its dummies — the deleted `DummyCombat` and
  `TrainingBotSystem` are not needed and not available), driven through the real `HitboxEngine`: a
  swing into a live parry window cancels the attacker's swing and staggers them; a swing into a block
  drains guard; a swing into a blocking defender's back reports `Backstab`; mutual parries in one
  `Step` report a single `Trade` and neither guard moves.
- Two cases specifically for the two-pass split, because they are the ones a single-pass
  implementation would silently pass the rest of the suite while getting wrong:
  - a hit whose `SampleTime` falls *before* `ParryStart` but which arrives in the same frame as
    the window opening resolves `Clean`, not `Parried`;
  - the one-frame cancel residual is asserted at its bound — a parried swing may land at most within
    the frame it was parried in, and not in the frame after.
- The whole suite plus `selene` / `stylua`, and a BOM scan on new files.

## Open questions

1. ~~**Do parry animations with markers exist yet?**~~ **Answered: no, and there are no clips at
   all.** `GetMarkerReachedSignal` and `KeyframeSequenceProvider` appear nowhere, and
   `Constants.AnimationIds` has no `Parry` or `Block` entry. Marker authoring is a real prerequisite
   for the *final* behaviour, but it no longer blocks the build — `ParryWindows.Register` covers the
   gap without weakening fail-closed. Authoring the clips remains scheduled work, not a dependency.
2. **How long is the stagger?** See *1.5s exceeds the previous design's derived upper bound*. This is
   the one open item that changes the feel of the system rather than its structure, and it wants
   deciding before the guard-drain numbers are tuned against it.
3. **Should a parry reflect projectiles?** Not addressed in the brief. The resolver is shaped to
   allow it later (a projectile is just another `HitReport` source) but nothing here implements it.
4. **Does a blocked hit still advance the attacker's combo?** Affects whether blocking is a reset or
   just chip. Recommend yes-with-reduced-advancement, but it is a design call.
5. **Does `Staggered` really warrant `RootControlLocked`?** The plan sets it for `Staggered` and
   `GuardBroken`, which hands the body to combat and stands the parkour framework down. For a 1.5s
   stagger in which the player can still block and still move (slowed), that reads more like a
   movement *modifier* than a loss of control, and `RootControlLocked` is a blunt instrument for it —
   it also suppresses every traversal. Worth confirming the intent is "cannot vault or wall-run out
   of a stagger" rather than incidental.
