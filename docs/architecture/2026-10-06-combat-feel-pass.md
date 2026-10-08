# Combat Feel & Network Pass — 2026-10-06

Scope: "combat feels clunky, not smooth like a battlegrounds game or Deepwoken." Follows
[`2026-09-28-combat-performance-audit.md`](2026-09-28-combat-performance-audit.md). Re-verified that
audit against current source first: F2, F4, F5, N1, N2, L1–L3 are fixed; F3 was still open and is fixed here.

Not verified in play: the suite needs Studio (`run-in-roblox`), which this pass did not have. selene and
stylua pass on every touched file, and a luau-lsp before/after diff shows no new type errors. **Playtest
these numbers before trusting them** — every one is a tuning value, not a design constant.

## 1. M1s link, and the read moved onto a stun parry (design change, owner-approved)

The diagnosis: a landed M1 was a deliberate parry *read* (2026-09-28/30). The defender came out of the
stun ~0.25s before the next punch, so every exchange broke after one hit into a scramble of blocks,
trades and clashes. That is the opposite of the battlegrounds feel.

- **Link** — `DamageConstants.Hitstun.LinkBasicString`. A Basic stage with a next stage stuns until that
  next hit lands: this swing's Active + Recovery + `ChainDelaySeconds` + the next Windup +
  `LinkMarginSeconds`. `AttackCatalog.Get` computes it from the **clip-synced** timeline, so every weapon
  at every WeaponSpeed/Tempo links without a hand-typed number. It only ever raises an authored stun. The
  **last** stage keeps its authored stun, so the end of a string is still a read before the launcher.
- **Stun parry** — `DefenseConstants.StunParry`. The air combo's held-body rule (B4), brought to the
  ground. While stunned:
  - the guard does nothing (Blocked becomes Clean);
  - an evade is still refused;
  - a timed parry counts, at `WindowScale` 0.75 of the normal window, stacking with Rally.

  A parry landed from the stun ends the stun at once (`DamageSystem.endHitstunOf`, and the client's
  `LocalCombatState.ClearHitstun` / `HitStop.EndVictimSlow`). Mashing fails on its own, because a whiff
  pays `Parry.RecoverySeconds` (0.45), which outlasts a link.
- **Tempo** back to 1 for Basic, with Fists at 1.1. On the shipped 0.583s clips, blade M1s land every
  ~0.63s (was 0.78) and Fists every ~0.40s (was 0.65).
- **Training bot** — perceives `SelfStunHeld` and answers a string with a parry only.

Specs:
- The old "parry read between M1s" spec is replaced by link specs: every linked stage covers the next
  impact; a Heavy off Basic 1 is still not guaranteed; the last stage keeps its stun; the rule switch
  works; the margin is greater than `RewindMaxSeconds`.
- DefenseSystem gets stun-parry specs. Its two stunned-press-waits specs now run with the rule off.
- DamageSystem gets a spec that a parry from the stun frees the parrier.

**Known trade-off:** a faster first M1 is less reactable. A Fists windup is now ~0.19s, and an opponent
sees a swing roughly a full round trip after the server's timeline started (see the 2026-09-28 L1
analysis). Answering the first hit is now mostly spacing or a pre-emptive guard, as in battlegrounds games.
The parry window rewind still covers the defender's own trip.

## 2. Swinging keeps part of the sprint

There was a misreading to correct first: combat never pinned you to 10. Walking pace is BaseWalkSpeed 10
plus the default BonusWalkSpeed 8, which is 18. What made chasing stop-start was each swing dropping a
sprint (×1.8, about 32) straight to 18.

`RunConstants.Combat.SwingGearCarry` (0.7): while the commitment is **only** the player's own swing (not a
stun, guard, stagger or guard break — `RunSystem.swingOnly`, which now mirrors `HitstunUntil`), speed is
base × max(1, held gear × 0.7). Swinging from a sprint gives about 22.7. The published stage stays walking.

## 3. Impact

- **String ender** — the last M1 of a string carries `StringEnd` on both `Combat_Feedback` and
  `Attack_Started`. The predicted hit therefore gets it too, rather than only the server's verdict, which
  a matched prediction would skip. It gives the attacker a HitHeavy shake and adds
  `FX.HitStop.StringEndBonusSeconds` (0.04). There is no extra knockback, because that would push the
  victim out of the 4th-press launcher's reach. `AttackCatalog.IsStringEnder` is the one definition.
- **F3 fixed** — a damage-number stack's text is its own Fusion Value in a per-stack scope. The keyed
  table changes only when a stack opens or closes, so a combo no longer rebuilds the label every hit. A
  stack now keeps its first hit's position and kind.

## 4. Network

Per landed hit in a 1v1 (re-measured from source):

| Traffic | Count | Notes |
|---|---|---|
| `Combat_Feedback` | 2 | Attacker and defender. Needed: damage numbers, stun mirror, push/launch ordering. |
| `Engagement_Changed` | ≤2 per 0.5s | Coalesced since 09-28 (N1). |
| `Defense_StateChanged` | edges only | |
| Replicated attributes | `CombatBusyUntil`, `HitstunUntil` | Both `math.max`-gated; `GuardFraction` quantised to 20 steps. |

Per swing: `Attack_Started` to the attacker only, plus `CombatBusyUntil`. `MovePresentationSystem`
broadcasts only on move edits. Nothing here fires unconditionally per frame.

**One race found and closed.** Against a laggy defender, DefenseSystem holds a Clean contact up to
`Parry.RewindMaxSeconds` (0.12) before applying it, in case a parry press is still in flight, and *that*
hit is what extends the stun. A link margin under the hold left the defender free on the server for the
difference — long enough for a buffered evade out of the middle of a string. `LinkMarginSeconds` is now
0.14, and a spec asserts margin > rewind.

Latency handling that already holds for linked strings, and needed no change:
- presses are buffered **server-side** (`Input.TransientRefusals` includes Busy/Hitstun), so the next
  link starts on the server's clock whatever the attacker's ping;
- `Latency.MaxLeadSeconds` refunds a late press up to 0.1s;
- swing and hit presentation are predicted on the attacker's client.

An attacker above ~200ms round trip whose presses are *not* buffered can still drop a link. That is the
cap on the refund doing its job.

## Still open

- Evade clips and sound are blank (`EvadeConstants.AnimationIds`/`Sound`). Each is a one-line id.
- ~~M1 step-in toward the lock-on target~~ -- **won't do**: owner decision (2026-10), never to be added.
  Only Heavy has a `SwingLunge`, and that stays.
- ~~Stagger length (1.5s / 1.8s perfect)~~ — shortened to 0.9s / 1.1s on 2026-10-07 (see
  `2026-10-06-combat-transactions-pass.md`, follow-ups).
- `docs/design/parry-block-system-plan.md` still says "proposed, not built".
