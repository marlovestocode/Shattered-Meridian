# Combat Transactions Pass — 2026-10-06

Scope: "find bugs, make combat transactions functionally faster, remove duplicated code." Follows
[`2026-10-06-combat-feel-pass.md`](2026-10-06-combat-feel-pass.md) and
[`2026-10-06-combat-consolidation-plan.md`](2026-10-06-combat-consolidation-plan.md). Every finding below was
re-verified against `constants-split` source before it was changed.

Not verified in play: the TestEZ suite needs Studio (`run-in-roblox`). selene and stylua pass on every touched
file. A luau-lsp before/after diff (message level) shows no new error in any modified file; the new
`CallbackList.lua` carries 54 lines of the two pre-existing repo-wide noise kinds (`LogFields?`, pcall's
"only returns 1 value") that the 200 removed elsewhere were made of — net −146. `CallbackList.spec` was
executed under plain Luau; the combat specs were not run.

Reviewed by an independent agent on a 1–10 loop: iteration 1 graded 6/10 (a no-op `SetWeapon` regression,
stale headers, a vacuous spec tail), iteration 2 graded 8/10 with no blocking issues. The decisions the review
forced are recorded inline below.

## 1. Bugs fixed

**B1 — Swing prediction was off for any player who drew a weapon instead of pressing swap.** The client
learns what it holds only from `Attack_WeaponChanged`, and that remote fired from `handleSwap` alone — never
on spawn and never on draw/sheathe (`SetWeapon`). With no weapon, `AttackInputClient.predictMoveId` returns
nil and every M1 waited a full round trip to show. After a draw it could also predict the *previous*
weapon's clip, corrected a round trip later. The `AttackInputClient` header claimed the bind-time message
existed; `DefenseClient`'s header correctly said it did not. Fix: `notifyWeaponChanged` (the one function
every change already goes through) now also tells the owner's client, and an empty hand is sent as nil.

Follow-on, found in review: once the client hears every change, a *no-op* change mattered. Re-selecting the
weapon already in hand (Y with only Fists) went through `SetWeapon` and notified, so the client reset its
string mirror while the server's string carried on — B1 predicted where the server threw B2, and Space came
back as a jump mid-launcher-window. `AttackRequestSystem.SetWeapon` now returns early for an unchanged weapon
(no notify, no dropped press, no Tool re-equip). The client still resets on every message, deliberately: the
swap key resets the server string even onto the same weapon, so a client-side "same id" guard would desync
that path instead.

**B2 — A buffered press survived a refusal that does not clear on its own.** `flushBuffers` re-throws each
frame but only acted on success. A press buffered mid-swing (`Busy`), followed by holding block
(`Guarding`) or a vault (`ParkourAction`), threw the moment that gate opened — within `BufferSeconds`
(0.35s) of the original press. Both gates' comments name exactly that free swing as what they prevent. Fix:
a flush that refuses for a non-transient reason drops and answers the press, the rule `rememberRefused`
already applies on arrival.

Design decision (from review): one guard waits instead of dropping — a guard that is still only a parry
window (`Raising`/`ParryWindow`, `waitsOutGuard`). That is the stun parry's counter: a stunned defender
buffers M1, presses parry, and the buffered swing is the counter-hit a landed parry earns. A window resolves
within tenths of a second (lands, whiffs, or settles into a held `Blocking`, which does drop), so it never
becomes "fires when you let go". Pinned by a spec.

**B3 — The defender's stun mirror ran long.** `Combat_Feedback.HitstunSeconds` was the contact's authored
length, and the client started it on arrival. But the server stun is timed from the contact, a contact
that waited out the rewind hold has already spent up to 0.12s of it, and the trip spends about half a
round trip more. So the client thought it was stunned for up to ~0.12s + one-way latency after the server
had freed it — its comeback swing and guard animation were held back by that much (0.20s rather than 0.12s
for an air-held defender, whose rewind cap is longer). Fix: the server sends the stun *still to run* at send
time (`DamageSystem.StunRemaining`, which also covers a hit inside a longer stun), and the client takes its
one-way trip off.

**B4 (type honesty)** — `AttackRequestSystem.OnWeaponChanged` advertised a non-optional weapon but has always
passed nil on sheathe; `AttackStartedPayload.WeaponId` likewise for an empty-handed art. Both subscribers
already handled nil. Signatures now say so.

## 2. Faster transactions

**T1 — First-press prediction (prediction seed).** The client only predicts a move it holds a server copy of,
and it got that copy from the move's first confirmation. So the first press of *every stage of every
weapon, every session*, waited a round trip. `Attack_WeaponChanged` now carries `Moves`: one
`Attack_Started` template per ground stage of the weapon in hand, built by the same `startedPayloadOf` the
real confirmation uses. Cost: one message per weapon change (≈5 small tables). Later confirmations overwrite
the templates, so a clip read mid-session self-corrects after its first throw. The client's stage counts now
come from the seed too, instead of a second copy of the Baseline length.

**T2 — No rewind hold where no press can matter.** `rewindHoldFor` held every Clean contact on a stunned
defender (the stun parry made a press meaningful). But a stunned body's guard does nothing, so only a parry
can answer — and a defender in their whiff lockout (the one who mashed parry through the string) has none.
Those contacts now apply immediately. In a linked string against a laggy masher, each hit landed up to
`Parry.RewindMaxSeconds` late before. Correctness: a press rewound to ≤ `now` meets a lockout at least as
long (only ever raised, through `math.max`); a press rewound past `now` (a release arriving mid-hold) opens
after the contact and cannot cover it. One behaviour change: a stun that ends inside the hold no longer lets
a rewound plain block mitigate the contact — that press was made while stunned, and the case is unreachable
inside a linked string (`LinkMarginSeconds > RewindMaxSeconds`).

Per-hit and per-swing message counts are unchanged from the feel pass's table.

## 3. Consolidation

- **`Shared/CallbackList.lua`** replaces fourteen hand-rolled subscriber lists: DamageSystem.OnApplied,
  DefenseSystem.OnResolved, HitboxEngine.OnHit/OnProjectileEvents, DomainSystem.OnPhaseChanged, the attack
  layer's OnPressRefused/OnWeaponChanged/OnSwingAccepted, AttackInputClient's OnAttackStarted/
  OnSwingCancelled/OnSlotCooldown, LocalCombatState's OnReleased/OnSwingCutRequested and LockOnController's
  OnTargetChanged. The copies shared a latent bug: a disconnect was a `table.remove` from
  the array being iterated, so a subscriber that unsubscribed during a dispatch made that dispatch skip the
  next one. CallbackList is copy-on-write (Fire allocates nothing — OnHit fires per contact) and skips a
  subscriber disconnected mid-dispatch. Four client lists were not pcall'd before (including
  `RequestSwingCut`, on the parkour evade path); now one listener erroring cannot stop the others.
  **Log change:** HitboxEngine's two subscriber errors used to log at warn as "OnHit callback errored"
  (`error` field); every list now logs at error as "A <Module.OnX> consumer errored" (`errorMessage` field).
  The remaining copies are all outside combat (CLAUDE.md lists them).
- **`startedPayloadOf`** — one builder for the confirmation and the prediction templates.
- **`SwingSequencer.StageMoveIds`** — the seed's ids from the same `stageMoveId`/`stageCountFor` Resolve uses,
  not a third copy of the id scheme.
- Outdated header text corrected: AttackRequestSystem's "NO CLIENT PREDICTION" (prediction of presentation
  has existed since 09-28), AttackInputClient's weapon-at-bind claim.

## Specs added

- `CallbackList.spec` — order, disconnect, self/cross disconnect mid-dispatch, late connect, error isolation, Clear.
- `AttackRequestSystem.spec` — a buffered press refused as Guarding at flush is dropped, answered, and never thrown.
- `DefenseSystem.spec` — no hold on a stunned, locked-out defender; still a hold on a stunned one who could parry.
- `SwingSequencer.spec` — `StageMoveIds` names exactly the stages Resolve throws (walked through Resolve).
- `AttackRequestSystem.spec` — a dropped press is never thrown when its gate reopens inside the old buffer
  window; a press waits through a stun parry's window; a re-select changes nothing; the seed matches the catalogue.
- `DamageSystem.spec` — `StunRemaining` is measured from now and follows the longer of two stuns.

## Still open

- Run the suite in Studio before trusting any of this.
- The non-combat subscriber lists.
- **Is `GetNetworkPing` a round trip or one way?** *(2026-10-07: now ONE flag, `Shared/PingReading.lua`'s
  `REPORTS_ROUND_TRIP`, read by every refund on both sides; `Client/DevTools/PingProbe.lua` measures it in
  Studio and logs the verdict to the Live Console. Still to do: run the probe and set the flag. The rest of
  this item is the original note.)* This codebase assumes round trip (`NetworkLatency`'s header).
  Roblox's reference page does not say, and DevForum measurements suggest ONE WAY (about half the ping
  in the stats overlay). If one way: the swing lead (`ping/2`) and the parry rewind (`min(ping, cap)`) refund
  half of what they mean to, the stun mirror's `ping/2` subtracts half a trip too little (harmless, errs
  long), and the client's `2 * GetNetworkPing()` prediction timeout is exactly one round trip (which is why
  it was NOT halved). Measure in Studio: print `GetNetworkPing()` beside the stats-overlay ping under the
  Network Simulator, then fix `NetworkLatency.PingSeconds` in one place.

## Follow-ups (2026-10-07)

- **Fists always in hand** when nothing else is drawn (`WeaponInventorySystem`, `inHandOf`); the HUD hides the
  Draw/Sheathe hint for Fists.
- **Stagger shortened** 1.5s → 0.9s, perfect 1.8s → 1.1s (`DefenseConstants.Stagger`/`PerfectParry`). M1s now
  link, so the stagger only has to cover the punish's first hit. Parrying back out of the stagger was
  already allowed (`Rally.ParryFromStagger`). The old rule "the combo window stays below the stagger" had
  been obsolete since parried melee swings started keeping their chain (2026-09-29); its spec now pins the
  one case nothing holds (a reflected shot that staggers its thrower) to under one Basic swing of leftover.
- **Checked and left alone:** a whiffed M1 does not reset the string (`SwingSequencer.Advance` runs on every
  accepted throw); the prediction timeout was not halved (see the `GetNetworkPing` question above).
