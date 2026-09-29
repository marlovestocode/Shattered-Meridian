# Air Combat + Combat Evade — design

Status: **APPROVED 2026-09-29.** Phase A (Combat Evade + the generic knockback interrupt) and phases B1-B4
(air combat) are built -- see "As built" at the end for where the build deviates from this text. Decisions as approved: the landing roll is cut; an air parry drops the attacker with
the ordinary stagger plus launch immunity; the launcher is reaction-parryable (0.42s windup); air hits
0.22s, finishers 0.34-0.40s; Space is the launcher modifier while a Basic string is live; no air-specific
whiff lockout. Max health is assumed to be 100 (unconfirmed).
Branch: `constants-split`. Every "today" claim below was checked against the current source on
2026-09-29; file references are to that tree.

Two systems, one document, because they share a spine: both are the combat stack taking a body
away from parkour for a short, server-decided window, and both need the parkour knockback gap
closed first.

- **Part A — Combat Evade.** The roll is deleted. Z becomes a ground glide that is the same move for
  a player and for the training bot, everywhere, every time.
- **Part B — Air Combat.** Designed from scratch: launcher → follow → air string → finisher, with the
  timed parry as the only way out.

---

## 0. What exists today (verified)

| Area | Today | Consequence for this design |
|---|---|---|
| Dodge | `Client/Parkour/States/Rolling.lua` is two moves in one: a **traversal roll** (1.6-stud crouch, 30 studs/s for 0.5s, plays the roll's tumble clip) and a **combat snap-step** (no crouch, 60 studs/s for 0.22s, `Dodge*` clips that are all blank, so no clip plays). It picks the snap-step only when `context.InCombat` or shift lock is on. | **This is why you still roll into the ground.** `InCombat` is a Humanoid Attribute EngagementSystem sets only once a fight is registered, and it is now throttled to one push every 0.5s. So the first dodge of every fight, and every dodge before the first traded hit, is the traversal tumble. The bot has no traversal branch, so it always glides. |
| Evade frames | `DefenseSystem.BeginEvade` opens `DefenseConstants.Evade` (startup 0, active 0.35). It is triggered from `Main.server.lua` when ParkourSystem accepts a `"Roll"` report. | Keep the mechanism. Rename the trigger. |
| Bot evade | `TrainingBotSystem.applyIntent` writes `AssemblyLinearVelocity = dir * Roll.CombatSpeed` for `Roll.CombatDurationSeconds`, with no clip. | The bot and the player need to share one motion curve, not two copies of the same numbers. |
| Knockback | `DamageSystem` resolves `DamageResult.Launch`. `KnockbackClient` applies it to the local player through `ParkourMotor.ApplyExternalImpulse`. `KnockbackAudit` checks it happened. | Good foundation. |
| **The parkour gap** | `ApplyExternalImpulse` records an interrupt while a Velocity state owns the body, but **only `Rolling` consumes it**. `Sliding`, `Dashing`, `Leaping`, `LedgeLeaping` and `WallRunning` re-command their own velocity on the next physics step and erase the knock. For Kinematic states (`Vaulting`, `Mantling`, `Ledge*`) the impulse is **refused outright**. | A launcher landing on a sliding, wall-running or vaulting player would silently not launch. Section B6 fixes it generically. |
| Combat ownership | `ParkourController.resolveCombatOwned` reads `RootControlLocked`/`Flying`/`Frozen`/`EmoteMovementLocked` and **force-transitions** into the `AerialCombat` parking state, even out of a Committed state. | This is the right hook for "air combat owns the body". The state name comes from the deleted design; it gets renamed (B6). |
| Air combo | `MoveKnockback.StartsAirCombo` and `RagdollSeconds` are validated, persisted and encoded by `MoveEditorSystem.encodeKnockback`, and **read by nothing**. `CombatConstants.AirCombo` has **zero readers**. `CombatConstants.AirSlam` backs a catalogued move, `default:AirSlam` (DefaultMoveRegistry's standalone list), that no request path can throw. | Reuse `StartsAirCombo` as the launcher flag, since it already round-trips. Mine the tables, then retire them (B7). |
| `MoveDefinition.Slam` | Typed and cloned in `MoveTypes`, but `SlamSystem.lua` does not exist, **`MoveEditorSystem.encodeMoveRecord` does not encode it**, and `MoveRegistryManager` never validates it (its own comment at :784 says so). | A trap: anything built on `Slam` would be lost on the DataStore round trip. The new finisher fields must not repeat it. |
| Parry | Judged in `DefenseSystem` pass 1 at each contact's substep `SampleTime`. The window is 0.2s from press arrival (`RegisteredParryWindows`), the end is extended by min(one-way ping, 0.12), perfect is the first 0.05, arming needs 0.3s unguarded (`MinUnguardedSeconds`), and a whiff locks out until `RecoveryEnd` (0.45 fallback). Rally shrinks the window per traded parry. | Keep all of it. The air parry adds one thing: a bounded contact hold so a press that is still in flight is not eaten (B4/B5). |
| Outcome fan-out | `DamageSystem.OnApplied` fires for **every** outcome kind, Parried and Evaded included (verified: `applyOutcome` returns early only on a catalogue miss). | AirComboSystem can learn about launches, air hits, parries and third-party hits from this one subscription. |
| M1 string | `SwingSequencer`: Basic is 3 stages (0.31s windup, 6.5 dmg on the house sword). Completing the string with `ComboEscalation` stage ≥ 3 tips into `Finisher`. Heavy is its own string. | The launcher is a branch off this string, resolved in the same `Resolve` call. |

---

# Part A — Combat Evade

## A1. The move

**One move, no variants.** Press Evade (Z / gamepad Y) on the ground and the body **glides**
along the ground in the held direction, or straight back with no input:
- It keeps its facing and never crouches.
- It never tumbles, and nothing about it is traversal.
- It is identical under shift lock or not.

The `InCombat` branch is what caused the bug, so there is no branch in the glide itself.

> **Amended 2026-09-28:** the evade is now **combat only**. `States/Evading.CanEnter` refuses it
> (`NotInCombat`) unless the `InCombat` Attribute is set, and `Main.server.lua` opens no evade frames
> for a player `EngagementSystem.IsInCombat` says is untagged. The tag lands on the first contact of a
> fight, so the opening swing of an exchange can only be blocked or parried, never evaded.

- **Motion:** a flash-step curve, fast out and eased in. `speed(t) = Peak * (1 - (t/T)^2)`, with
  Peak = 78 studs/s and T = 0.24s. That covers **12.5 studs**, 80% of it in the first 0.15s, and reads
  as a teleport-glide rather than a run. One pure function, `EvadeMotion.SpeedAt(t)` in
  `Shared/Combat/EvadeMotion.lua`, is used by the player's state **and** the bot's server-side drive,
  so the two can never drift apart again.
- **Facing:** held at the value it had on press. A dodge must not hand an opponent a backstab
  bearing.
- **Direction:** held input (camera-relative `MoveIntent`), else straight back from facing. Four
  directional clips (`EvadeForward/Back/Left/Right`) are optional. While unauthored, **no clip plays**
  (the bot's current look), and the existing `Client/FX/RollAfterimage.lua` draws a 3-ghost afterimage
  plus a low dust streak so the glide reads as a flash-step instead of a slide.
- **Ground only.** In the air, Dash is the move. The press is refused there, not buffered into a
  landing roll.
- **Refused** while combat-committed (own swing, hitstun), grabbed, mounted, air-held (Part B), or on
  cooldown. These are the same body gates `DefenseSystem.BeginEvade` already applies on the server.
- **Cooldown:** 0.9s, unchanged. The server evade cooldown stays derived from it.
- **Evade frames:** startup 0, active **0.30s**, covering the 0.24s glide plus a margin. The ping
  refund is unchanged.
- **Knockback wins.** A launch mid-glide ends it (the generic interrupt rule in B6).

## A2. What is cut, and what that costs

The Rolling state goes, and with it:
- **The landing roll** (roll within 0.2s of touchdown to skip Landing's momentum cut and camera dip).
- **The roll-out of a slide.**
- **The ceiling crawl.**

Traversal loses the landing-roll skill expression. **Recommendation: accept that.** The
alternative is keeping a traversal roll on the same key, which is exactly the two-moves-one-key
design that produced the bug. If you want the landing save back later, it should be a separate
Landing-state feature ("press Evade on touchdown to keep momentum, no roll clip"), not a roll.

## A3. Files

- **New:**
  - `Client/Parkour/States/Evading.lua`
  - `Shared/Combat/EvadeMotion.lua`
  - `Shared/Combat/EvadeConstants.lua` (Peak, T, cooldown, frames)
  - `Tests/Parkour/EvadingState.spec.lua`
  - `Tests/Combat/EvadeMotion.spec.lua`
- **Deleted:**
  - `States/Rolling.lua`
  - `ParkourConstants.Roll`
  - `Tests/Parkour/RollingState.spec.lua`
- **Edited:**
  - `StateSupport` (`CanRoll` → `CanEvade`)
  - `Falling`, `Sliding` and `Landing` (their roll routes removed)
  - `InputBuffer` (`PressRoll` → `PressEvade`)
  - `ParkourInput` and the keybind table: the action is renamed Roll → Evade, **with a migration for
    saved binds stored under "Roll"**
  - `ParkourAnimator` and `ParkourAudio` entries
  - `ParkourTypes` (`ActionKind` `"Roll"` → `"Evade"`)
  - `ParkourValidation` (bounds for the new speed profile)
  - `DefenseConstants.Evade` (derives from `EvadeConstants`)
  - `Main.server.lua` (the trigger kind)
  - `TrainingBotSystem` (drives `EvadeMotion.SpeedAt`)

---

# Part B — Air Combat

## B0. Hakuda: what we take, what we change

**Taken from Type Soul's Hakuda air game:**
- The shape: an M1 string branches into an uptilt launcher, you go up with them, run air M1s, and
  cash out with a slam.
- The launcher on **Space + M1** mid-string.
- Air M1s that are fast and rhythmic, where the rhythm itself is the mind game.
- A downward slam as the default cash-out.

**Changed:**

| Hakuda | Here | Why |
|---|---|---|
| You manually jump after the victim, so the follow is a timing input that drops under ping. | **Auto-follow**, driven on the attacker's own client from a server-published anchor. Spacing error still exists (drift and facing, B2), but ping cannot cause it. | Brief (1): never drops because of lag. |
| The victim's air escape is mostly lag-dependent: blocks and parries the server judges late. | The **timed parry is the only escape**, and an air parry is judged with a bounded **rewind** to when the victim actually pressed on their screen (B4/B5). A held block does nothing. | Brief (1) and the "one way out" rule. |
| Air hits land with little ceremony. | Hit-stop, camera punch and sound **on every air hit**, scaling up to the finisher. The air parry gets its own clash, distinct from a ground parry. | Brief (2): weight. |
| One real cash-out. | **Two finishers that do different things.** Slam is damage now; Spike is position and guard pressure. Both can be thrown from air hit 1 onward, and each grows with the string length behind it. | Brief (3): route choice. |
| Hard to read as a spectator. | A replicated phase Attribute plus a distinct visual per phase: launched, held, parried out, dropped, recovered (B4). | Brief (4): readability. |
| Relaunch and juggle loops possible. | One launch per combo, per-victim **launch immunity** after any combo ends, a fixed string length, and a finisher that always ends it. | Bounded by design. |

## B1. The combo state model

### Owner

**`AirComboSystem`**, a new **sibling** of AttackRequestSystem, shaped like GrabSystem:
- It subscribes to `DamageSystem.OnApplied`.
- It is read by `AttackRequestSystem.Throw` through `AirComboSystem.CanAttack(model, now)`, a fourth
  CanAttack-shaped gate.
- It boots after GrabSystem and gets a BootManifest entry.
- The rules live in a pure, clock-injected `AirComboMachine.lua`, the same discipline as
  DefenseStateMachine, so the whole life cycle is spec-driven with no rig.

Files:
- `Server/Combat/AirCombo/AirComboSystem.lua`
- `Server/Combat/AirCombo/AirComboMachine.lua`
- `Shared/AirCombo/AirComboConstants.lua`
- `Shared/AirCombo/AirComboTypes.lua`
- `Client/Combat/AirComboClient.lua` (attacker follow)
- `Client/FX/AirComboFX.lua` (readability and weight, for every client)

### Published state (Humanoid Attributes, the only cross-system channel)

Deadlines are written in **`workspace:GetServerTimeNow()`** time, not `os.clock()`, because clients
read these (existing Attributes such as `HitstunUntil` are server-only and use `os.clock`, and that
difference is deliberate).

| Attribute | On | Meaning | Read by |
|---|---|---|---|
| `AirHeldUntil` (number) | victim | The victim is held until this time. | `AirComboSystem.CanAttack`; DefenseSystem pass 1 (block → nothing, evade refused); `DefenseSystem.BeginEvade`; `ParkourController.resolveCombatOwned`; the ParkourSystem report gate; RunSystem movement lock |
| `AirComboAttackerUntil` (number) | attacker | The attacker is committed to a combo until this time. Their Basic/Heavy resolve to air moves. | `SwingSequencer.Resolve` (via AttackRequestSystem); `resolveCombatOwned` on the attacker's client; the ParkourSystem report gate |
| `AirComboAnchor` (Vector3) | both | The hover point. The attacker's client computes its follow slot from it. | `AirComboClient`, `AirComboFX` |
| `AirComboPhase` (string) | both | `Rising` / `Held` / `Finishing` / `Parried` / `Dropped` / `Recovering` / `Slammed` / `Spiked` / cleared | `AirComboFX` on every client (spectator readability), the HUD |
| `LaunchImmuneUntil` (number) | victim | Cannot be launched again until this time. | `AirComboSystem` itself (and the bot's brain) |

### One shared deadline

Taken from the old `AirCombo.AirborneSeconds` lesson: hold, follow and continuation used to run on
two constants, and hits that visibly connected got rejected as "late".

Here the machine keeps a single `ContinueBy`, and everything derives from it:
- The victim's hold (`AirHeldUntil`).
- The attacker's commitment.
- The drop.

Each landed air hit sets `ContinueBy = contactTime + ContinueSeconds`. Nothing else extends it,
except the in-flight-swing grace in B5.

### Every way a combo ends

The machine has one `End(reason)`. Each reason sets a phase, releases the victim's body back to
their own client, and writes `LaunchImmuneUntil`.

| Reason | Trigger | Victim | Attacker |
|---|---|---|---|
| `Finished` | A finisher lands (Clean). | Slam or Spike outcome (B3). | Lands normally. |
| `Parried` | The victim parries an air hit or a finisher. | Freed, falls, lands first. | Parry-dropped: normal stagger rules, falling (B4). |
| `Dropped` | `ContinueBy` passes with no in-flight in-time swing (a late press, a whiff, or bad spacing). | Falls and recovers. | Falls, free. |
| `Interrupted` | The **attacker** takes any Clean/Backstab/GuardBroken hit from anyone. | Falls and recovers. | Normal hit reaction. |
| `SpacingFail` | Attacker root > `FollowToleranceStuds` from its slot for > `FollowGraceSeconds` (server audit, B5). | Falls and recovers. | Falls, free (logged). |
| `Timeout` | `now > LaunchedAt + MaxComboSeconds` (hard cap, whatever else happens). | Falls and recovers. | Falls. |
| `Aborted` | Either dies, despawns, disconnects, is grabbed, or mounts. | Released. | Released. |

A dropped victim's recovery:
- They fall under ordinary gravity with the body returned to their own client.
- On touchdown they are free immediately. A drop is the attacker's fault, so the victim pays no
  knockdown.
- `LaunchImmuneUntil = end + 2.5s` in every case, so there is no instant relaunch.

## B2. Input grammar

### The launcher branch (ground)

- **Space + M1 as the 4th M1** -- after B3, while the Basic string is live -- throws
  `default:{weapon}:Launcher`, provided all three Basics LANDED (`ComboEscalation` >= 3). That is B1, B2, B3,
  then Launcher. **It is the only 4th hit an M1 string has** (revised 2026-09-28 at the user's request): the
  old tip of a fully-landed string into the weapon's Finisher is removed, so a plain M1 after B3 starts a
  fresh string at B1 once the end-of-string lockout passes. The launcher itself skips that lockout -- it is
  the string's 4th link, and a 0.5s pause before it would outrun the combo window it needs.
- If the conditions are not met, Space + M1 is just the next Basic (no dead input).
- **The wire:** `AttackRequest` gains an optional `Modifier: "Up"?`. The client sets it when Space is
  held at the press. The server decides whether it means anything (`SwingSequencer.Resolve` gets the
  modifier), so a forged modifier can only ask for a launcher the string already earned.
- **Space must not jump there.** While the local Basic string is live (the client already mirrors it
  in `LocalCombatState`), the Space press is held as a modifier instead of jumping. That is the
  Hakuda convention and the same precedent the old finisher jump-suppression set. Outside a live
  string, Space jumps as normal.

### The air string

Once the launch lands, the attacker's Basic resolves to `default:{weapon}:Air:{n}` (n = 1..3) and
Heavy resolves to a finisher. Timings are per move, from clip Hit markers via AttackWindows; the
numbers below are the authored defaults.

```
launch contact ─┬─ Rising (0.30s) ─┬──────── air hit 1 ───────┬──── air hit 2 ──── ...
                │                  │                          │
                │   first press may be thrown from            each landed hit sets
                │   launch + FirstPressSeconds (0.18)         ContinueBy = contact + 0.90
```

For each beat after a landed air hit at time `h`:

| Window | Time after `h` | What a press there does |
|---|---|---|
| Locked | `h` → `h + ChainReady` (≈0.20: remaining active + 0.16 recovery) | Buffered (existing 0.35s input buffer), thrown at ChainReady. |
| **On-beat** | `h + 0.20` | The fastest follow-up. The next hit lands at `h + 0.20 + W`. |
| **Delay** | `h + 0.20` → `h + 0.90 − W` | Legal delay. With W = 0.22, **0.48s of delay space** per beat. This is the bait tool. |
| **Late (drops)** | after `h + 0.90 − W` | The swing is thrown but its hit would land after `ContinueBy`. The victim is released before it lands and the combo ends `Dropped`. The attacker's HUD flashes the beat marker red at the moment it became late. |

Rules:
- A whiffed air swing (facing wrong, drifted out of range) does not refresh `ContinueBy`. If there is
  time left, you may throw again.
- **Fixed length:** after Air:3 lands, the next Basic press throws the Slam finisher automatically.
  The string cannot continue past it.
- **Choosing a finisher**, from air hit 1 onward:
  - **Heavy** → **Slam**.
  - **Space + Heavy** → **Spike**.
  - Finishers obey the same delay and late windows as any beat.
- **Drift:** the attacker keeps WASD within a `DriftRadius` (4 studs) disc around the slot and must
  keep the victim in front of them. Facing is assisted (the body turns to the victim at a capped turn
  rate) but not locked, so looking away mid-string can whiff. That is where "bad spacing" lives
  without ping ever causing it.

## B3. Routes, with numbers

Defaults are house-sword scale and assume 100 max health (every value is Move Editor authored per
move except the scaling rules, which live in `AirComboConstants`). Weapon multipliers (for example
Fists) apply on top, exactly as they do to Basic.

**Scaling:**
- **Air hits scale down.** Air hit `k` (0-based count of air hits already landed) deals
  `base × max(0.6, 1 − 0.1k)`.
- **Finishers scale up with the string behind them**: `base + perHit × airHitsLanded`. That makes
  running the read worth more than cashing out at once, instead of early cash-out dominating.
- **ComboEscalation is frozen** at its launch value for the whole air combo. The two scalings never
  stack.

| Move | Windup | Damage | Posture | Notes |
|---|---|---|---|---|
| Launcher | **0.42** | 7 | 10 | Knockback UpVelocity is used only as the rise's initial spring velocity. `StartsAirCombo = true`. Blockable, parryable and evadeable like any move. Blocked or whiffed, it has a 0.35s recovery, so it is punishable. |
| Air:1 / Air:2 / Air:3 | **0.22** each | 4 | 6 | Scaled 1.0 / 0.9 / 0.8. |
| **Slam** (finisher) | 0.40 | 8 + **2.5 per air hit** | 12 | Drives the victim straight down. Impact: +3 (scaled with the finisher). **Hard knockdown 0.9s**, during which the victim is intangible (no hits land) and wakes where they fell. The attacker lands 0.25s before the victim is actionable. |
| **Spike** (finisher) | 0.34 | 6 + **1.5 per air hit** | 10 | Sends the victim along the attacker's facing (70 horizontal, −25 vertical). **Drains 35% of max guard** (`DefenseSystem.DrainGuard`, the existing seam). A wall in the path within 1.2s means a **wall splat**: 0.8s hitstun through `DamageSystem.ExtendHitstun`, the path the environment system already uses. Launch immunity still stands, so the follow-up is a ground string, never a relaunch. |

**Route totals** (B1 6.5 + B2 7.0 + Launcher 8.1 with escalation = 21.6 on the ground):

| Route | Air part | Total |
|---|---|---|
| Launcher → Slam (0 air hits) | 8 | ~30% |
| → Air1 → Slam | 4 + 10.5 | ~36% |
| → Air1 → Air2 → Slam | 7.6 + 13.0 | ~42% |
| → Air1 → Air2 → Air3 → Slam (full) | 10.8 + 15.5 | **~48%** |
| → Air1 → Air2 → Air3 → Spike | 10.8 + 10.5, guard −35%, possible splat | ~43% plus pressure |

- A full route is strong and never a kill from full.
- Each extra air hit is +6% for one more parry guess.
- Slam against Spike is damage now against position and guard.

**Hover and follow:**
- Victim anchor = launch-contact root position + **8 studs** up. The old 12 read as "too high to
  follow".
- **Rise 0.30s**, as an underdamped spring (frequency 9, damping 0.55), so the victim
  overshoots about 0.6 studs and settles. The overshoot is what sells the launch.
- Each air hit kicks the spring 6 studs/s upward, giving a small, weighty bob per hit.
- **Attacker slot** = anchor − 3.5 studs along the attacker→victim flat direction − 1.5 studs down.
  These are the old standoff and below-offset numbers, which were right.
- Timing caps: `FirstContinueSeconds` = 1.1 (the first beat has a longer budget to absorb the follow),
  `ContinueSeconds` = 0.90, `MaxComboSeconds` = 4.0, launch immunity 2.5s.

## B4. The air parry, end to end

**Timing:** the ordinary parry, with nothing changed except B5's rewind:
- A press arms a 0.2s window (rally-scaled) if the victim has been unguarded ≥ 0.3s and is not
  locked out.
- Holding block through the combo leaves them in Blocking. Blocking against an air hit on an air-held
  defender resolves as **Clean**. The one rule DefenseSystem gains is `AirHeld and Blocked → Clean`,
  applied in pass 1 from the Attribute.
- To parry, the victim must release, wait out `MinUnguardedSeconds`, and press on the read. A whiff
  locks them out until `RecoveryEnd`.

**What the numbers mean for the read:** with W = 0.22 on air hits, a parry must be pressed in
[W − 0.2, W] = **0.02–0.22s after the windup becomes visible**:
- Pure reaction parries it only at elite reaction speed. Most players must read the beat (on-beat
  or delayed).
- Finishers are slower (0.34–0.40) and are **reactable**. Cashing out raw into a waiting victim gets
  parried, so a finisher has to be set up by conditioning, which is the route-choice tension.
- A whiff costs 0.2s window + 0.45s recovery + 0.3s unguarded ≈ **0.95s**, about two on-beat beats.
  With 3 air hits and a finisher, a baited whiff on beat 1 or 2 leaves the victim at most one more
  guess. That is "the bait costs the combo" in practice.
- **Recommendation: no air-specific lockout.** If you want a whiff to cost literally the rest of the
  combo, the knob is `AirComboConstants.WhiffLocksOutRemainder = true`, but it breaks "same parry
  rules everywhere", so I would not ship it on.

**Outcome, victim:**
- The combo ends `Parried`.
- The body returns to the victim's own client, and they fall.
- They land about 0.1s before the attacker, because the attacker is pushed up and back 4 studs/s on
  the clash.

**Outcome, attacker (DECISION: drop them, with the normal stagger):**

| Option | Verdict |
|---|---|
| Just end the combo | Too cheap. A read made under pressure should win more than "reset to neutral". |
| Stagger in the air (freeze them aloft) | Invites a juggle of the attacker, which is a reversed combo. Out. |
| **Drop + ordinary stagger** (recommended) | The attacker falls, **staggered by the standard rules** (`Stagger.DurationSeconds` 1.5; a perfect parry gives 1.8). The victim lands first with about 0.8s of stagger left on the attacker, **enough for one ground string, and never a launcher**: the attacker gets `LaunchImmuneUntil` too, so a parry can never become a reversed air combo. Rally still applies, so the staggered attacker may parry back on the ground under the shrinking-window rule. |

**Feedback, "unmistakable":**
- A dedicated **air-clash** effect, distinct from the ground parry: 0.12s hit-stop on both, a white
  ring shockwave at the contact, a bright metallic ring layered with a bass thump, and a 0.35
  camera-punch FOV kick on both clients. A perfect parry adds a second ring, a longer freeze (0.18)
  and a slow-mo tail on the parrier's camera.
- Phase goes to `Parried`, with a short blue flash on the parrier's outline visible to spectators.

**Readability for spectators** (the `AirComboPhase` Attribute, every client, no extra remote):

| Phase | Victim | Attacker |
|---|---|---|
| `Rising` / `Held` | A red streak under the body, the body pinned to its spring, a faint vertical light column. | Subtle wind trail. |
| `Parried` | Blue flash plus shockwave. | Stagger stars and a tumble-fall pose. |
| `Dropped` | A grey "released" puff, then they fall limp. | — |
| `Recovering` | A short white shimmer on landing (free again). | — |
| `Slammed` | Dust crater plus a downed pose. | — |
| `Spiked` | Speed lines plus a guard-crack flash. | — |

## B5. Networking under ping

### The victim's body: server-owned while held

On launch the victim gets `SetNetworkOwner(nil)` + `PlatformStand` + `RootControlLocked`. This is
GrabSystem's proven technique.

The server integrates the hover with `FlightMath.SpringStep` each Heartbeat and drives it through a
LinearVelocity toward the spring's position, so the victim's server position is authoritative for
every hitbox and cannot be moved by the victim's client.

- **Why not client-owned:** server hitboxes test against server positions. A client-owned victim is
  seen late by the server and can be dragged out of the hover by a modified client.
- **Cost:** the victim sees their own body with server→client delay. They have no movement input, so
  they cannot feel it.

On any `End`, ownership is returned through a Trove cleanup, so it cannot be skipped by an error.

### The attacker's body: client-owned

`AirComboClient` on the attacker's machine starts the follow **the moment its own launcher's hit
confirm arrives**. It springs the attacker to the slot computed from `AirComboAnchor`, with drift
and facing assist.

The victim is pinned, so the attacker's latency barely matters: the target does not move. The
first beat's longer budget (`FirstContinueSeconds`) absorbs the one-RTT late start.

### "Never drops because of lag" — two concrete mechanisms

1. **In-time swings are honoured.** The attacker's press reaches the server one-way latency late.
   `ContinueBy` is judged against the swing's **rewound start**, `acceptedAt − min(attackerPing,
   0.12)`. If `rewoundStart + W ≤ ContinueBy`, the hold is extended until that swing's active window
   ends. The attacker is only ever dropped for a press that was late **on their own screen**.
2. **The air parry is never eaten by lag.**
   - The victim sees the windup late by server→victim latency, and their press reaches the server
     late by victim→server latency. On the ground today, a press that was on time on screen can
     arrive after the contact was already classified Clean. The existing refund only extends the
     window's end, so it cannot rescue a press that has not arrived yet.
   - For **air-held defenders only**, DefenseSystem's pass 2 **holds a Clean contact** for up to
     `D = min(victim round-trip, AirComboConstants.ParryRewindMaxSeconds = 0.20)` instead of
     applying it.
   - If a block press arrives during the hold, it is judged at its **rewound press time**
     `arrival − min(RTT, 0.20)`: would a window armed then (same MinUnguarded and lockout checks,
     evaluated at that time; **no additional end refund**, the rewind replaces it) contain the
     contact's `SampleTime`? If yes, the contact resolves **Parried**. Otherwise it applies as Clean
     when the hold expires.
   - The judgement stays on DefenseSystem's own substep clock, so it is the same parry, judged on the
     victim's timeline.
   - **Why only when air-held:** on the ground the defender has other options and a deferred hit
     would stall every exchange. In the air the parry is the only option, so a generous, capped rewind
     cannot be abused for anything else.
   - **The cost, stated honestly:** against a laggy victim, the attacker's hit confirmation (and its
     hit-stop) can arrive up to 0.20s later on air hits. The attacker's own swing animation is
     unaffected.
   - **Cheating:** `GetNetworkPing` is server-measured, the cap bounds any gain, and the rewind never
     applies outside an air hold.

### Server audits

- **Spacing:** attacker root within `FollowToleranceStuds` (7) of its slot after `Rising` +
  `FollowGraceSeconds` (0.35). A breach ends the combo `SpacingFail` and is logged. A client that
  refuses to follow just drops its own combo, which is harmless.
- **Parkour:** ParkourSystem refuses Start reports from either participant while their
  `AirHeldUntil`/`AirComboAttackerUntil` is live (Attribute read, no require).
- **Remotes:** **no new remote.** The modifier rides `Attack_Request` (existing rate limiter), state
  rides Attributes, and hit and clash feedback ride the existing `Combat_Feedback` payload with one
  optional `AirCombo` field.

## B6. Parkour, and closing the knockback gap

1. **A generic interrupt rule.** `ParkourController` asks `ParkourMotor.ConsumeInterrupt()` **before**
   running *any* Velocity-drive state's Update, and hands off to `Falling` or the grounded resolver
   carrying the impulse. This fixes Sliding, Dashing, Leaping, LedgeLeaping and WallRunning in one
   place instead of five per-state copies. Evading uses the same rule and needs no bespoke code.
2. **Kinematic states stop refusing.** `ApplyExternalImpulse` against a Kinematic owner (vault,
   mantle, ledge) releases the kinematic rig, force-transitions to Falling, and applies the impulse.
   A knock mid-vault is a knock.
3. **An air-held body is not parkour's.** `resolveCombatOwned` adds `AirHeldUntil` and
   `AirComboAttackerUntil` (compared against `GetServerTimeNow`), so both participants are
   force-parked. That transition already overrides Committed states. The parking state is renamed
   `AerialCombat` → **`CombatHeld`**, since it is a generic "combat owns this body" park and the
   old name describes the deleted design.
4. **Participants cannot start parkour.** On the client via the park, on the server via the report
   gate (B5).
5. **Launching a victim mid-parkour just works.** Server ownership plus RootControlLocked takes the
   body regardless of what the client was doing. That is the gap closed for air combat specifically,
   on top of the generic fix for ordinary knockback.
6. **An attacker mid-parkour cannot launch:** `ParkourOwnership.OwnsBody` already refuses attacks
   during a reported parkour action.

## B7. The old AirCombo / AirSlam tables

- **`CombatConstants.AirCombo`:** zero readers, **deleted** in phase B1.
  - Kept as numbers: HoverHeight (lowered to 8), standoff 3.5, below-offset 1.5, and matched
    rise/follow pacing.
  - Kept as a principle: the single shared deadline.
  - Discarded: ParryHoldExtensionSeconds, the priority switch, all AlignPosition-responsiveness
    tuning, the dummy-only pop, and the slam's separate constants.
- **`CombatConstants.AirSlam`** backs `default:AirSlam`, a catalogued, Move-Editor-editable move with
  possibly persisted overrides and no request path.
  - Its authored values seed the new Slam finisher's defaults.
  - Then it is removed from DefaultMoveRegistry's standalone list, in the same phase that adds the
    finisher, after checking that `loadDefaultMoveOverrides` tolerates an orphaned override id (and
    making it skip with a warning if it does not).
- **`Types.lua` / `MoveTypes.lua` prose** describing `AirCombo.Apply` and `RagdollController` is
  rewritten to describe the new system.
- **`MoveKnockback.RagdollSeconds`** stays authored and inert. There is still no ragdoll, and the
  header will say so plainly.
- **`MoveDefinition.Slam`** (never encoded, never validated) is **not** reused. It is flagged as a
  separate cleanup.

## B8. Move authoring and the DataStore round trip

- **Launcher:** `Knockback.StartsAirCombo = true`. It already validates, encodes and persists.
- **Air moves and finishers:** a new optional `AirRole` on MoveDefinition:
  `{ Role: "Air" | "Finisher", Finisher: ("Slam" | "Spike")?, PerHitBonus: number? }`.
- Added in **every** place a field has to be to survive: the `MoveTypes` type, Clone and
  Fingerprint; `MoveRegistryManager` validation (with clamps); `MoveEditorSystem.encodeMoveRecord`;
  the Move Editor UI section; and `DefaultMoveRegistry` stage ids (`Launcher`, `Air:1..3`,
  `AirFinisher:Slam`, `AirFinisher:Spike` per weapon).
- A **round-trip spec** encodes, decodes and compares a move carrying every new field, so this cannot
  silently become another `Slam`.

## B9. Testing

**Specs (TestEZ, synthetic clock, no rig):**
- `AirComboMachine.spec`: every end reason; the ContinueBy arithmetic (on-beat, max delay, late
  drop); the in-flight rewound-swing grace; one launch per combo; launch immunity; the fixed length
  with auto-finisher; finisher damage growth; frozen escalation.
- `DefenseSystem` air cases:
  - Blocked → Clean while held.
  - Evade refused while held.
  - The rewind hold: a press arriving within D whose rewound time covers the contact becomes Parried;
    one outside becomes Clean; a press violating MinUnguarded at its rewound time stays Clean.
  - The perfect-parry band under rewind.
  - Rally interaction.
  - The hold never applies to a non-held defender.
- `SwingSequencer`: the Launcher branch conditions; a forged modifier without an earned string throws
  a Basic; air resolution while `AirComboAttackerUntil` is live; the finisher modifier.
- `ParkourController`/motor: the generic interrupt ends each Velocity state; a Kinematic state
  accepts an impulse.
- `EvadeMotion`/`EvadingState`: the curve integrates to the distance, facing is held, ground-only,
  the gates.
- The MoveEditor round-trip spec (B8).

**TrainingBotSystem:**
- **Phase B3:** the bot is a launch target. It goes through the same OnApplied path, and its body is
  already server-owned, so the hover drives it directly.
- **Phase B3:** the bot **parries out** of air combos. Its existing rhythm read (the swing-cadence
  EMA, `RhythmRead`, `TimingErrorSeconds`, `MisreadChance`) is applied to air beats. Each air swing is
  a `SwingView` like any other, so it naturally gets baited by delays at a difficulty-scaled rate. The
  ParryTrade style parries every air hit perfectly, as a stress test for the clash.
- **Phase B4:** the bot **launches you**. The Brain learns the Launcher as a plan branch after B2
  lands, then runs air beats with a difficulty-scaled delay mix and picks Slam or Spike by distance to
  the nearest wall.

**Playtest checklist** (per phase, things only Studio can prove): the glide look; the rise feel; the
follow at 150ms+ ping (Studio's network emulation); the parry rewind under emulated lag; the clash
weight; spectator readability from a second client.

## Phases (each shippable)

Every phase ends with: selene 0/0, `stylua --check` on touched files, the ParkourConstants BOM
stripped, the suite run (I ask first if Studio is open), and an inbound-require check on every new
module. I report what was verified against what needs a playtest.

| Phase | Ships | Playable result |
|---|---|---|
| **A** | Combat Evade (Part A) + the generic knockback interrupt (B6.1–2) | Z glides for everyone, always. Knocks are never eaten by parkour. |
| **B1** | `AirComboMachine` + `AirComboSystem` skeleton, the Attributes, launch, hover (server-owned victim), every end reason, the CanAttack gate, the parkour park, the old-table deletion | A move flagged `StartsAirCombo` launches and holds. The combo ends on a drop or timeout. Tested with a dev-authored launcher. |
| **B2** | Input grammar: the Launcher branch, air string resolution, finishers (Slam/Spike), `AirRole` authoring + round trip, damage scaling, attacker follow client | The full route is playable. |
| **B3** | The air parry: Blocked→Clean, the rewind hold, the parry-drop outcome, the clash FX; the bot as a launch target that parries out | The one-way-out loop is complete and tested against the bot. |
| **B4** | Weight and readability pass (hit-stop, camera and sound per hit, spectator phase visuals); the bot launches you | Feel and polish. |

## Decisions I need from you

1. **Part A:** cut the landing roll with the Rolling state (recommended), or rebuild it later as a
   Landing feature?
2. **Air parry vs the attacker:** drop + ordinary stagger with launch immunity (recommended)?
3. **The launcher on reaction:** a 0.42s readable windup, reaction-parryable, balanced by its
   mix-up with Basic 3 / Heavy timings (recommended)? Or tighten it to 0.34 so it is read-only?
4. **Air-hit windup 0.22** (read, not reaction), finishers 0.34–0.40 (reactable)?
5. **Space as the launcher modifier:** Space does not jump while your Basic string is live. OK?
6. **No air-specific whiff lockout** (recommended), or ship `WhiffLocksOutRemainder`?
7. **Numbers:** a full route of about 48%, assuming 100 max health. If max health differs, tell me and
   I will rescale.

## As built (B1-B4)

Where the build deviates from the text above, and why:

- **No `AirRole` field on MoveDefinition (B8).** The launcher, air beats and finishers are ordinary
  *Default* moves -- `default:{weapon}:Launcher`, `:Air:1..3`, `:AirFinisher:Slam|Spike`, built per weapon
  from `CombatConstants.Weapons.Baseline.Stages.Launcher/Air/AirFinisher` -- so their role is read off the id
  (`Shared/AirCombo/AirComboMoves.lua`) and they are already Move Editor tunable and persisted through the
  Default-override record. A Basic/Heavy press only ever resolves Default ids, so an `AirRole` authored on a
  custom move would have had no reader. A custom move still launches through `Knockback.StartsAirCombo`.
  No new persisted field means no new round-trip spec.
- **Borrowed clips.** No air clip is authored yet, and this repo does not guess asset ids, so each air move
  plays the ground clip closest to it (air beats = the three M1s, launcher and spike = the finisher's, slam =
  the heavy's) -- **retimed**, so the lender's strike marker lands on the air move's own windup
  (`AttackCatalog.Get` step 0). Author `LAUNCHER`/`AIR1-3`/`SLAM`/`SPIKE` clips (shared `AttackAnimations`
  ids or a weapon's `Animations` folder) to replace them; an authored clip follows the ordinary marker rules.
- **Damage scaling** is one hook slot on DamageSystem (`SetAirComboHook`) rather than an `OnApplied`
  subscriber rewriting `result.Damage`, so every `OnApplied` consumer (kill credit included) reads the damage
  actually dealt. Air hits and finishers are flat-priced like M1s; the launcher escalates like a heavy.
- **The rewind hold** uses `Player:GetNetworkPing()` as the round trip, capped at 0.20s. The in-time-swing
  grace is extended by the victim's own rewind hold so a held hit never lands after the combo has dropped.
- **The launcher is the 4th M1 (after B3), not the 3rd**, and the Finisher is no longer thrown by M1s at
  all (user revision). The Finisher move stays catalogued because the launcher and the Spike borrow its clip.
  Space stops jumping from the moment B3 is thrown.
- **Slam knockdown intangibility** is its own Attribute (`AirComboIntangibleUntil`), read by DefenseSystem pass
  1 as Evaded.
- **RunSystem is unchanged.** Both participants are platform-standing while the combo holds them, which
  already suspends walking.
- **`CombatConstants.AirCombo` and `AirSlam` are deleted**, and `default:AirSlam` with them. A persisted
  override for it is never read again (the override loader walks the live registry).
- **Spectator FX are built from primitives** (parts, Highlights, a Trail) in `Client/FX/AirComboFX.lua`, so
  they work before any asset is uploaded. Air hits keep the ordinary hit-stop/sparks/audio every Clean hit
  gets; the `AirCombo` feedback tag adds the camera punch, the finisher weight and the clash on top.
- **The evade no longer sinks into the ground.** Both the evade glide and the dash's landing tail used to
  command a downward surface stick at the parkour drive's full force, which beat the Humanoid's hip support
  and buried the R6 legs. Both now drive the horizontal plane only.

- **A parried swing keeps the chain (2026-09-29, user).** The parried swing does not spend its stage:
  B1 and B2 land, B3 is parried, and after the stagger M1 is B3 again with the launcher one press behind it.
  A parried launcher leaves the string at B3, so Space + M1 tries the launcher again. The string and the
  landed combo are both held through the stagger (`SwingSequencer.RestoreParried`,
  `DamageSystem.HoldCombo`, wired in `AttackRequestSystem.KeepChainThroughParry`). A parried AIR hit still
  ends the combo and keeps nothing. The punish (stagger length, the parrier's free combo) is unchanged.
- **Arts weave into any weapon's string (2026-09-29, user).** An Art is a link that holds the string's
  place (`SwingSequencer.Weave`): B1, B2, an Art, then M1 is B3, and B1-B3 + Art + Space + M1 still launches.
  The string cannot lapse during the art, the landed combo cannot lapse before the art's hit window closes,
  and the next link owes the ordinary chain beat after it. Nothing reads the weapon, so fists included.
