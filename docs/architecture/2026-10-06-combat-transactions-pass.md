# Combat Transactions Pass — 2026-10-06

Scope: "find bugs, make combat transactions functionally faster, remove duplicated code." Follows
[`2026-10-06-combat-feel-pass.md`](2026-10-06-combat-feel-pass.md) and
[`2026-10-06-combat-consolidation-plan.md`](2026-10-06-combat-consolidation-plan.md). Every finding below was
re-verified against `constants-split` source before it was changed.

Not verified in play: the TestEZ suite needs Studio (`run-in-roblox`). selene and stylua pass on every touched
file; a luau-lsp before/after diff shows no new type errors in them (net −176, almost all the pcall-loop
noise the new `CallbackList` replaced). `CallbackList.spec` was executed under plain Luau; the combat specs
were not run.

## 1. Bugs fixed

**B1 — Swing prediction was off for any player who drew a weapon instead of pressing swap.** The client
learns what it holds only from `Attack_WeaponChanged`, and that remote fired from `handleSwap` alone — never
on spawn and never on draw/sheathe (`SetWeapon`). With no weapon, `AttackInputClient.predictMoveId` returns
nil and every M1 waited a full round trip to show. After a draw it could also predict the *previous*
weapon's clip, corrected a round trip later. The `AttackInputClient` header claimed the bind-time message
existed; `DefenseClient`'s header correctly said it did not. Fix: `notifyWeaponChanged` (the one function
every change already goes through) now also tells the owner's client, and an empty hand is sent as nil.

**B2 — A buffered press survived a refusal that does not clear on its own.** `flushBuffers` re-throws each
frame but only acted on success. A press buffered mid-swing (`Busy`), followed by holding block
(`Guarding`) or a vault (`ParkourAction`), threw the moment that gate opened — within `BufferSeconds`
(0.35s) of the original press. Both gates' comments name exactly that free swing as what they prevent. Fix:
a flush that refuses for a non-transient reason drops and answers the press, the rule `rememberRefused`
already applies on arrival.

**B3 — The defender's stun mirror ran long.** `Combat_Feedback.HitstunSeconds` was the contact's authored
length, and the client started it on arrival. But the server stun is timed from the contact, a contact
that waited out the rewind hold has already spent up to 0.12s of it, and the trip spends about half a
round trip more. So the client thought it was stunned for up to ~0.12s + one-way latency after the server
had freed it — its comeback swing and guard animation were held back by that much. Fix: the server sends
the stun *still to run* at send time (which also covers a hit inside a longer stun), and the client takes
its one-way trip off.

**B4 (type honesty)** — `AttackRequestSystem.OnWeaponChanged` advertised a non-optional weapon but has always
passed nil on sheathe; `AttackStartedPayload.WeaponId` likewise for an empty-handed art. Both subscribers
already handled nil. Signatures now say so.

## 2. Faster transactions

**T1 — First-press prediction (prediction seed).** The client only predicts a move it holds a server copy of,
and it got that copy from the move's first confirmation. So the first press of *every stage of every
weapon, every session*, waited a round trip. `Attack_WeaponChanged` now carries `Moves`: one
`Attack_Started` template per ground stage of the weapon in hand, built by the same `startedPayloadOf` the
real confirmation uses. Cost: one message per weapon change (≈5 small tables). Later confirmations overwrite
the templates, so a clip read mid-session self-corrects after its first throw.

**T2 — No rewind hold where no press can matter.** `rewindHoldFor` held every Clean contact on a stunned
defender (the stun parry made a press meaningful). But a stunned body's guard does nothing, so only a parry
can answer — and a defender in their whiff lockout (the one who mashed parry through the string) has none.
Those contacts now apply immediately. In a linked string against a laggy masher, each hit landed up to
`Parry.RewindMaxSeconds` late before. Correctness argument: every rewound press time is ≤ `now`, and the
lockout only ever lengthens, so refusing at `now` refuses at all of them.

Per-hit and per-swing message counts are unchanged from the feel pass's table.

## 3. Consolidation

- **`Shared/CallbackList.lua`** replaces ten hand-rolled subscriber lists: DamageSystem.OnApplied,
  DefenseSystem.OnResolved, HitboxEngine.OnHit/OnProjectileEvents, DomainSystem.OnPhaseChanged, the attack
  layer's OnPressRefused/OnWeaponChanged/OnSwingAccepted, and AttackInputClient's OnAttackStarted/
  OnSwingCancelled/OnSlotCooldown. The copies shared a latent bug: a disconnect was a `table.remove` from
  the array being iterated, so a subscriber that unsubscribed during a dispatch made that dispatch skip the
  next one. CallbackList is copy-on-write (Fire allocates nothing — OnHit fires per contact) and skips a
  subscriber disconnected mid-dispatch. Two client lists were not pcall'd before; now one FX listener
  erroring cannot stop the others. About ten non-combat copies remain (CLAUDE.md lists where).
- **`startedPayloadOf`** — one builder for the confirmation and the prediction templates.
- **`SwingSequencer.StageMoveIds`** — the seed's ids from the same `stageMoveId`/`stageCountFor` Resolve uses,
  not a third copy of the id scheme.
- Outdated header text corrected: AttackRequestSystem's "NO CLIENT PREDICTION" (prediction of presentation
  has existed since 09-28), AttackInputClient's weapon-at-bind claim.

## Specs added

- `CallbackList.spec` — order, disconnect, self/cross disconnect mid-dispatch, late connect, error isolation, Clear.
- `AttackRequestSystem.spec` — a buffered press refused as Guarding at flush is dropped, answered, and never thrown.
- `DefenseSystem.spec` — no hold on a stunned, locked-out defender; still a hold on a stunned one who could parry.
- `SwingSequencer.spec` — `StageMoveIds` names exactly the stages Resolve throws.

## Still open

- Run the suite in Studio before trusting any of this.
- The ten non-combat subscriber lists.
- The client's prediction timeout uses `2 * GetNetworkPing()`, which is a round trip already — harmless (it is
  only the backstop now that refusals are answered) but twice what it needs.
