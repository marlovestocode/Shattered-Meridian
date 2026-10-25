# Deepwoken-informed combat pass — 2026-10-25

Scope: the whole combat loop (attack lifecycle, parry/block, posture, evade, feints, combos, networking), measured
against Deepwoken's observable design. Every finding was checked against current source on this date, including the
uncommitted work from the earlier 2026-10-25 audit session (`2026-10-25-codebase-audit.md`), which this pass kept.

## 1. Reference: what Deepwoken does, and what we take from it

Sources: [Combat Mechanics](https://deepwoken.fandom.com/wiki/Combat_Mechanics) and
[Version History/2026](https://deepwoken.fandom.com/wiki/Version_History/2026) (both read 2026-10-25),
[Controls](https://deepwoken.fandom.com/wiki/Controls). Deepwoken's source is not public. Everything below is
observable behaviour or patch-note wording, and the numbers are theirs, not ours.

| Mechanic | Deepwoken (observable) | Counterplay / failure mode | Shattered Meridian | Verdict |
|---|---|---|---|---|
| Parry | Press F: a brief deflect stance. A success stuns the attacker, cancels the attack, restores the parrier's posture, resets the parry cooldown, and gives 0.3s of auto-parry. A miss costs a 1.2s cooldown, but you can hold to block. | Mashing is priced by the miss cooldown. Failure mode: moves that "inconsistently don't cancel on parry" (2026 fix). | Clip-marker window, ping refund plus rewind hold, whiff lockout, stagger, `ParryRestore`, a held key behind a spent window blocks, rally windows shrink. | Preserved. Richer than the reference (rally, perfect parry). No change. |
| Block | Hold F after the window. Front only (some moves are 360°). Fills posture. A hit right after makes a "shaky block". | A block that also lets damage through, or one that blocks from behind. | Arc + rear hemisphere -> Backstab, staggered blocks mitigate less, guard drain by PowerLevel. | Preserved. |
| Posture / block-break | A separate bar. Blocked hits build it. Overflow = a guard break stunning about 1.05s, and the posture resets. A parry restores it. | **An unending break.** Deepwoken resets posture, so a break is one opening. | Guard doubles as posture, and clean hits drain it too (a design choice, kept). | **Bug, fixed (F1)**: the break re-stamped on every punish hit, and the pool left the break empty. |
| Dodge | i-frames with a cooldown; it can be roll-cancelled. 2026: "ping compensation not reevaluating dodges after the delay … basically did nothing for dodges", and "dodges in high ping… seemingly dodge on your client but get hit anyway". "Fixed being able to roll mid stun." | A dodge eaten by lag. Rolling out of stun. | Server evade frames with an end-only ping refund. Refused in stun, mid-swing, staggered or broken. | **Gap, fixed (F3)**: the same gap Deepwoken patched. Stun refusal already correct. |
| Feint | M2 during the windup (the pull-back). Cooldown, slight end lag. Most criticals can't be feinted. 2026 fix: "swing faster after a mantra feint… if that mantra was not able to be casted". | Option-selecting off a visible parry. A failed cancel leaving partial state. | `WindowFraction` of the windup, cooldown, recovery rewrite, buffer drop, Feintable per move. A refused feint changes nothing. | **Timing gap, fixed (F2)**: the window lost the press's own one-way trip. |
| M1 string / flourish | 3 hits then a flourish that knocks back to end the string. Getting hit locks M1 out a little longer than the roll. | Infinite strings. | Linked M1 stun, a string-ender with knockback, chain delay, stun parry as the answer, a clash rule. | Preserved. |
| Stun / combo end | Hit stun lowers speed, disables rolling and cancels attacks. Uppercut combos drop both players on a parry. | Infinite hitstun, launch loops. | `ExtendHitstun` (never shortens), launch immunity 2.5s, air parry rewind. | Preserved. No loop found. |
| Attack properties | Telegraphs: parry-only, dodge-only, unblockable. 2026: telegraphs account for whether *your* posture can block it. | Unblockables without a tell. | Heavy tell (PowerLevel ≥ 2), projectile `CannotParry`, realm rules. `combat-philosophy.md` #3 forbids an untelegraphed unblockable. | Preserved. No new properties added (none needed by current content). |
| Dead/removed bodies | — | Hits that land after death. | See F4. | **Bug, fixed (F4)**. |

## 2. Findings

| # | Sev | Finding | Owner |
|---|---|---|---|
| F1 | **P0** | A guard break could last for as long as the pressure did. A clean hit drains posture through `DrainGuard`. On the emptied pool `GuardMeter.ApplyDrain` reports `broke`, so every punish hit called `BreakGuard` and restarted the 1.0s window: no block, parry, evade or swing while hit once a second. Separately, the pool left the break still empty (each hit had pushed its regen delay out), so the next hit broke it again. | `DefenseStateMachine.BreakGuard`, `DefenseSystem.DrainGuard`, the registration's transition hook |
| F2 | P1 | The feint window was measured as arrival time minus a start backdated by one-way latency, so the feint press's own trip counted against the window. At 100 ms one way, a 0.25s window lost 40%. | `AttackRequestSystem.Feint` |
| F3 | P1 | The evade had no lag rewind. Parry and block presses that arrive during the rewind hold are judged at their rewound time, but an evade press was not, and the evade's end-only refund forgives early presses, never late-looking ones. | `DefenseStateMachine` (`CanEvadeAt`, `BeginEvade`), `DefenseSystem` (`evadeBodyRefusal`, `evadeNotBefore`, `rewindHoldFor`, `resolveHeldEvadesFor`) |
| F4 | P2 | A contact classified while its defender lived but applied after the lethal blow (a second hit in the same batch, or one leaving the rewind hold) ran in full: hitstun, a push, combo credit, and `OnApplied`, where `EngagementSystem` re-tagged a victim `PlayerKilled` had just cleared. They respawned "in combat" (a regression path for 2026-10-08 audit finding #5). | `DamageSystem.applyOutcome` |

## 3. Changes

- **F1.** `BreakGuard` is a no-op while already `GuardBroken`. `DrainGuard` absorbs drains while `GuardBroken` (returns
  `guard, 0, false`). A `Stagger` landing inside a break extends the break instead of replacing it (the mirror of
  `BreakGuard`'s existing max rule). Leaving `GuardBroken` runs `onGuardBreakEnded`, which resets the pool to full
  (`GuardMeter.Reset`) and drops the batch's cached guard for that body. Nothing is held in the rewind hold while
  broken. The break is still exactly `GuardBrokenSeconds` from the hit that caused it (longer only if a stagger lands
  inside it), and still a real opening. **Design consequence:** a broken defender comes out with a whole guard, as in
  Deepwoken.
- **F2.** `InFlight.LeadSeconds` records how far each swing was backdated. `Feint` judges its window at
  `now - min(OneWaySeconds, LeadSeconds)`, so it never refunds more than the swing itself was. The engine must still
  be in `Windup` at `now`, so a hitbox that has opened is never cancelled retroactively.
- **F3.** The evade's window is now ANCHORED AT THE PRESS. `BeginEvade(now, rewindSeconds, notBefore)` opens it at
  `now - min(round trip, Evade.RewindMaxSeconds)`, never before the previous evade's cooldown, a stagger, a guard
  break, or `notBefore` (`max(HitstunUntil, CombatBusyUntil)`). It keeps its authored length and has no end refund, so
  a higher ping shifts the window and never lengthens it. (The first draft added a rewound window on top of the old
  end refund: up to 0.54s of frames at a 120 ms round trip against 0.30s at zero ping. Review caught it.) Contacts are
  held for an evade press in flight only while the body is `InCombat` (the evade is combat-only), off cooldown, free
  of the body gates, and not guard-broken. Clean hits from any bearing and Backstabs on a raised guard qualify. An
  accepted evade resolves every held contact inside its window as `Evaded`. A stunned or swinging body holds nothing
  for an evade, so linked M1 strings are not delayed. **Trade, deliberate:** against a laggy, free, tagged defender,
  flank and rear hits now wait out the hold (≤ 0.12s) the way frontal ones already did. **Residual:** the
  instantaneous gates (grab, mount, freeze, air-hold, a realm's NoEvade) keep no history, so a press can be rewound
  up to 0.12s across their end. This is the same residual the attack layer's swing lead accepts.
- **F4.** `applyOutcome` drops Clean/Backstab/GuardBroken/Blocked on a defender at `Health <= 0`. A parry, trade or
  evade by someone who then died still settles the attacker's swing and is still reported to them.

## 4. Left alone, deliberately

- Clean hits draining posture (Deepwoken builds posture only on blocks). This is an established design here
  (`DrainGuard`'s header), and F1 bounds its worst case.
- No auto-parry after a landed parry. The held-key-blocks-behind-a-spent-window rule covers the same surround case
  without a free parry.
- No new melee defensive properties (unparryable/unblockable crits). No current move needs one, and the philosophy
  doc requires a telegraphed cost for any.
- Parry timings, stun-parry, rally, the clash rule, hit-confirm cancels, buffering and the hurtbox broadphase were
  traced and are consistent. No change.

Also, from review: `AttackRequestSystem.CancelRecoveryForEvade` now lowers `CombatBusyUntil` to the cut (never below a
running stun), the same bare write `Feint` makes. Before, a hit-confirm evade got no rewind, because the cut swing's
deadline still read as committed.

## 5. Validation (what was actually run)

- `selene src/`: 0 errors. The 2 warnings are the pre-existing `UDim2.fromScale` ones in `UI/Screens/Inventory/init.lua`.
- `stylua --check` on every touched file passes (run on LF copies; the checkout is CRLF, see CLAUDE.md).
- Full TestEZ suite (`rojo build test.project.json` + `run-in-roblox`), final tree: **3494 passed, 43 failed**. A clean
  `HEAD` worktree run the same way: **3458 passed, 43 failed**, with an **identical set of failing tests**. So this pass
  adds no failure. The 43 belong to other areas: AttackAnimations, AttackCatalog clip timing, the feint "abandons the
  string" and "feint cooldown" cases, MoveRegistryManager/MoveTypes, WeaponInventory, TierSystem, UI Inventory/Shell,
  and DefenseSystem "is hit during the startup" (`Evade.StartupSeconds = 0` makes that case's premise false). All 17
  cases this pass added or changed ran and passed.
- **Not verified in Studio/play:** the feel of the widened rewind hold (flank/rear hits on laggy, tagged defenders),
  the full guard refill after a break, and the feint refund. Playtest at 150-200 ms round trip.

## 6. Independent review

Four repository agents reviewed the change, read-only, over two rounds: combat-systems, chief-architect, performance and
physics-movement. Round 1 found the defects listed below, all fixed:

- Evade compensation stacked (up to 0.54s at a 120 ms round trip, against 0.30s at zero ping). This was exploitable
  by padding ping.
- The fight's opener was held for an evade the server would refuse.
- A Backstab was not held for the evade.
- A stagger inside a break refilled the guard early.
- Hits on a broken guard were held.
- A rewound press could reach into a stagger or a swing's recovery.
- Two equal caps were not tied together.
- Docs had gone stale.

| Reviewer | Round 1 | Round 2 |
|---|---|---|
| Combat systems (responsiveness, consistency, fairness, combos, architecture, networking, performance, tests) | 6, 6, 6, 7, 8, 6, 8, 5 | 7, 8, 8, 7, 8, 8, 8, 7 |
| Chief architect (cohesion, networking, tests, maintainability) | 6, 6, 6, 7 | 8, 8, 7, 8 |
| Performance | 8 | — |
| Physics/movement (networking, movement integration) | 5, 6 | 8, 7 |

Three scores stay below 8:

- **Responsiveness 7, combo flow 7.** The remaining cost is the open gap below. It predates this pass for frontal hits,
  and F3 widens it to flank/rear hits.
- **Tests 7.** The new behaviour has specs, but the 43 pre-existing failures leave the suite red as a gate.
- **Movement integration 7.** This is the unclamped instantaneous gates (residual above).

## 7. Open follow-ups

1. **A held hit leaves the defender free on the server.** `HitstunUntil` is only written when a hit applies, so during
   the rewind hold the defender can start a swing that the held hit then cancels ("my M1 came out and got eaten").
   Candidate fix: a provisional hold deadline that `AttackRequestSystem`'s body gate reads. That is a design change
   to how the hold and the attack gate meet, not a patch.
2. **Make the suite green.** The 43 pre-existing failures, mostly fixtures drifting from authored clip and asset data.

   > **Correction (cohesion audit, 2026-10-25).** The area list in §5 was approximate. Measured and classified one by one, the 43 were: 34 fixture drift (pasted asset ids, shapes the engine re-learned, stand-ins missing an API or not registered as combatants, an identity-less round trip, a stale clock), 1 real contract breach (`FpsCounter`'s raw DisplayOrder), 1 harness limit (`GuiButton.Activated` cannot be fired by a script), 2 feint cases that read as a real gap (inferred from source: `CancelString` leaves the end-of-string lockout) and 5 TrainingBot cases not resolved to a cause. 36 pass now; see `2026-10-25-cohesion-audit.md`, A8.
3. **Playtest** the three unverified feel changes above at 150-200 ms.
