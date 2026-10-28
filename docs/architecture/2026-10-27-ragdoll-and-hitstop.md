# Ragdoll system and hit-stop smoothness pass (2026-10-27)

## Hit-stop: why it felt stuck

Three causes, all in `Client/FX/HitStop.lua` and `Client/Combat/CombatFeedbackClient.lua`:

1. **Unbounded freeze chains.** Every freeze (0.09–0.2 s) was longer than the 0.1 s throttle, so hits that arrived back to back (a string, a volley, two attackers) each *extended* the hold. Both bodies' arms stayed frozen for as long as hits kept arriving, then caught up at 1.5x for twice as long again.
2. **Latency stacked on the beat.** A server verdict arrives one-way latency after the contact, and the full freeze was held from the moment it arrived.
3. **Launch delays ignored the real freeze.** A knockback or push waited out the outcome's *table* freeze length even when no freeze had started (throttled), so the body was neither frozen nor moving for a beat.

What changed (`FXConstants.HitStop`):

| Rule | Value | Effect |
|---|---|---|
| `MaxChainSeconds` | 0.22 | Overlapping freezes merge into one hold, capped. A freeze that would not extend the hold is dropped, and it can never shorten one. |
| `ChainGapSeconds` | 0.06 | Free motion after a chain before the next can start. |
| `MinFreezeSeconds` | 0.03 | Shorter freezes are skipped (a hitch, not a beat). |
| `AgeByLatency` / `MinStingerSeconds` | on / 0.04 | A verdict's freeze is shortened by its one-way trip, never below a stinger. Predicted impacts keep the full beat. |
| `SlowReleaseSeconds` | 0.12 | The stun slow eases back to full speed instead of cutting from a crawl to a sprint in one frame. |

Launches and pushes now wait out `HitStop.VictimFreezeRemaining()` / `ExchangeRemaining()`, the freeze that is actually running. The maths is pure (`AgedSeconds`, `ChainedSeconds`, `SlowMultiplierAt`) and pinned by `Tests/FX/HitStop.spec.lua`.

## Ragdoll

```
Move.Ragdoll (RagdollTypes)          authored block; one field list drives Validate, Copy and the editor
      │  MoveTypes.ToEngineAttackDefinition -> DamageProfile.Ragdoll
      ▼
DamageResolver                        copies the block in the landed branches (Clean / Backstab / GuardBroken)
      ▼
DamageSystem.ragdollFor               RagdollRules.Resolve: the trigger, the death fallback, the anti-lock Attributes
      │                               -> DamageResult.Ragdoll (final), BEFORE OnApplied
      │                               ragdolled: launch not handed to the client, no spacing push, feedback.Ragdolled
      ▼  OnApplied
RagdollSystem (sibling, CombatTick)   applies exactly that spec: claims RootControl, server takes the body,
                                      throws it, polls rest, gets it up, hands it back
      └─ RagdollRig                   the Instances: sockets aimed per joint class, colliders, gravity forces, drives
```

- **Why DamageSystem decides.** A ragdolled body's launch belongs to the ragdoll (server-simulated), so DamageSystem must know before it fires `OnApplied` not to hand the launch to the victim's client, not to push it, and KnockbackAudit must not expect one. The damage layer cannot require the runtime above it, so the runtime publishes `Ragdolled` / `RagdollChainEndsAt` / `RagdollImmuneUntil` (sole writer: `RagdollSystem`, enforced by `check-single-writers.py`) and `RagdollRules.Admits` reads them.
- **Server holds a limp body**, players included: `SetNetworkOwner(nil)` on every part (each limb is its own assembly while limp), returned to the player standing. The client stands down on the RootControl claim and PlatformStand.
- **Restraint.** `Ragdolled` is a new BodyRestraint restraint, last in the Swing, Guard (so no stun-parry out of a fall), Evade, Parkour, LocalSwing, Emote, Judge and Launch rows. Move and CameraMotion are covered by the RootControl claim.
- **Anti-lock.** A ragdolling hit on a limp body refreshes it (juggle) until `Rules.MaxChainSeconds` from the first fall; after getting up the body is immune for `Rules.ImmunitySeconds`. A killing blow is never refused.
- **Death.** A lethal hit from a move without a block uses `RagdollConstants.Death.Spec` instead of the engine's joint break.
- **Refused beside** a launcher (`StartsAirCombo`) at validation, and at runtime for air-combo participants, grabbed/grabbing, mounted and frozen bodies. A ragdolled body is never grabbed.
- **Grab moves ragdoll on the throw.** The grab hit itself never ragdolls (the body is welded into a hand). `GrabSystem.OnThrown` announces the throw the frame the body leaves the hand; `RagdollSystem.onThrown` reads the move's block off `AttackCatalog`, resolves it against the grab's contact kind with the body airborne (On kill never fires on a throw), and throws it with the throw velocity as the launch. GrabSystem's flight carries on for landing/impact damage, and its `restoreControl` leaves a Ragdolled body's velocity, ownership and PlatformStand alone. The get-up always clears PlatformStand.
- **Cost.** No work with nobody limp. Before `DurationSeconds` a limp body is a deadline compare; after it, one velocity read per poll (`Settle.PollHz`, offset per body); only a body getting up writes per frame. The rig is built once per life and toggled after. Constants and the spec are read once per ragdoll, so a tune applies to the next one.
- **Any move.** Default (weapon) moves may carry the block through their override (`DefaultMoveRegistry`, `MoveRecordCodec.DecodeOverride`). The Move Editor's Impact tab has a RAGDOLL section built from `RagdollTypes.Fields`, with presets (Crumple, Launch, Spiral, Slam, Float, Execution).

Replaced: `CombatConstants.Ragdoll` (no readers since RagdollController was deleted).

## Not verified

- The TestEZ suite was not run in this session (Studio was open; `run-in-roblox` would hijack it).
- Nothing was playtested: the fall, the get-up, ownership hand-back on a live player and the hit-stop feel all need a session in Studio.
