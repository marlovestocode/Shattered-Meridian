# Progression Spine Audit and Decision Record

**Date:** 2026-09-28
**Branch:** `constants-split` (dirty tree — Vessel/Boat extraction, Constants split, settings/UI WIP all
uncommitted and preserved; nothing here reverts or reformats them)
**Supersedes:** nothing. [`2026-08-19-audit.md`](2026-08-19-audit.md) stays the combat/boot baseline; its
§3 stub list is **stale** (see ledger row L-11). [`2026-08-audit.md`](2026-08-audit.md) and
[`2026-07-audit.md`](2026-07-audit.md) are historical only.
**Method:** every row below was re-verified against current source on this date; citations are
`file:line` in the current tree. Tests cited were run, not assumed — see "Verification".

---

## 1. Runtime flow, as it is now

```
Player input ──► AttackRequestSystem (request only; server-authoritative)
                   │
   HitboxEngine ──► DefenseSystem ──► DamageSystem ──┬─► Humanoid:TakeDamage ─► Humanoid.Died
                                                     │                             │
                          OnApplied (fires BEFORE ───┤                             │
                          the health write)          ├─► GrabSystem  (sibling)     │
                                                     ├─► EngagementSystem (sibling)│
                                                     └─► PlayerDeathSystem ◄───────┘
                                                           kill credit + exactly-once death
                                                                   │
                                   GameplayEvents.PlayerKilled(victim, killer?, deathId)
          ┌───────────────┬──────────────┬──────────────┬──────────┴───┬──────────────────────┐
     RespawnSystem   RewardSystem   RivalrySystem   BountySystem   BloodlineSystem   Blimp/Boat/Emote
     (every death)   (attributed)    (standings)   (streak/claim)  (interim stage-up)  (cleanup)
                          │
                   RewardManifest (frozen)
                          │
                  ProgressionSystem.Apply   ← legitimacy gate + routing
                          │
                  MeridianSystem.AwardKillXP → PlayerDataSystem.Transform
                          │
            GameplayEvents.MeridianXPAwarded ─► TierSystem.Evaluate ─► TierChanged ─► QiSystem, RaceSystem
```

Dependency direction (arrows = `require`, all one-way, no cycles):

```
PlayerDeathSystem ──► DamageSystem ──► DefenseSystem ──► HitboxEngine
PlayerDeathSystem ──► GameplayEvents ◄── RewardSystem ──► ProgressionSystem ──► MeridianSystem ──► PlayerDataSystem
                                     ◄── Rivalry / Bounty / Bloodline / Respawn (subscribers)
TierSystem ──► GameplayEvents (subscribes MeridianXPAwarded)   — never required by the spine
```

## 2. Decisions

**D1 — Kill attribution belongs to PlayerDeathSystem, through `DamageSystem.OnApplied`.**
The death is the one-shot moment where "exactly once" must be enforced, so the module that confirms
deaths also owns who caused them. It subscribes to the extension point DamageSystem documented for
exactly this (`DamageSystem.lua:218-232`); DamageSystem gains nothing and requires nothing new. Rejected:
DamageSystem publishing deaths (widens a combat layer upward, and it cannot see environmental deaths);
a generic damage event bus (a second transport for one consumer).

**D2 — Credit rule: health actually removed, by a different, still-present player, on the same life,
within `DamageConstants.KillCredit.WindowSeconds` (10s); last valid blow wins.** Keyed per life (the
character Model), cleared on respawn, on confirmed death and on PlayerRemoving — including credit a
leaver holds against someone else, because publishing a departed Player would re-insert them into
Rivalry/Bounty tables their own PlayerRemoving scrub already cleaned (a leak, not a wasted reward).
*Deviation from the brief, flagged:* the brief said "blocked outcomes never create credit". A guarded
`Blocked` prices to 0 and so earns nothing, but a `Blocked` landing on a **Staggered** guard removes
real health (`DamageResolver.lua:147-150`) and can be lethal; denying it credit would make that kill
environmental. The rule implemented is "health removed", tested both ways. Reverse it by adding a
`Kind` check in `PlayerDeathSystem.RecordDamage` if that is the intended design.

**D3 — `PlayerKilled` gains `deathId`.** (victim, killer) cannot distinguish a replayed fact from a
second genuine kill of the same pair. A server-lifetime monotonic id is one field and gives
RewardSystem an O(1) replay guard (a high-water mark) with no Player-keyed table to lifecycle.

**D4 — RewardSystem composes, ProgressionSystem gates and routes, owners compute.** RewardSystem is the
only PlayerKilled subscriber on the progression path; it produces a frozen manifest from a frozen
taxonomy (`PvPKill → { MeridianXP }`). ProgressionSystem owns the fight-to-grow gate
(`LEGITIMATE_SOURCES = { PvPKill }`, no self-reward, non-empty) and a frozen route table; the only
route is `MeridianSystem.AwardKillXP`, which owns the amount. Direct one-way calls, not events: each
hop has exactly one consumer, and the chain is ordered (a manifest must be gated before it is routed).
MeridianSystem's interim `OnPlayerKilled` subscription was removed in the same change, so there is one
award path, not two.

**D5 — Domain types live in `Shared/Progression/ProgressionTypes.lua`,** not `Shared/Types.lua`. The
one new tunable lives in `Shared/Damage/DamageConstants.lua`, not `Shared/Constants.lua`.

**D6 — No fake machinery.** No Absorb component (AbsorbSystem is an empty roadmap entry with no
balance authority), no milestone call into an empty AchievementSystem, no anti-farming rule (a balance
decision — see open item O-2).

## 3. Audit ledger

Status: **resolved** (fixed this pass, with evidence) · **open** · **stale** (a doc/audit claim current
source contradicts) · **new** (found this pass) · **negative** (checked, nothing wrong).

| # | Item | Citation (current) | Status | Impact | Owner | Phase | Evidence |
|---|---|---|---|---|---|---|---|
| L-1 | Every death published `killer = nil`; Meridian/Bounty/Rivalry/Bloodline kill paths unreachable | `PlayerDeathSystem.lua:172-193` (was `FirePlayerKilled(player, nil)`) | **resolved** | Critical — the core loop could not progress anyone | PlayerDeathSystem | 1 | `Tests/Progression/PlayerDeathSystem.spec.lua` (20 cases) |
| L-2 | PlayerDeathSystem booted before DamageSystem existed | `Main.server.lua:287-299` | **resolved** — now after DamageSystem, before AttackRequestSystem; Init asserts DamageSystem | High | Main.server.lua | 1 | boot order + `Init` assert |
| L-3 | Reward/Progression were empty `Init(): () end` placeholders | `RewardSystem.lua:83-160`, `ProgressionSystem.lua:77-137` | **resolved** | High | Reward/ProgressionSystem | 2 | `Tests/Progression/ProgressionSpine.spec.lua` (21 cases) |
| L-4 | MeridianSystem awarded via its own interim PlayerKilled subscription | `MeridianSystem.lua:102-104` (subscription removed) | **resolved** — single award path | Would double-award once the spine existed | MeridianSystem | 2 | spine spec "exactly one award" cases |
| L-5 | Reward/Progression booted in the PLANNED loop | `Main.server.lua:176-188`, `BootManifest.lua:155-159` | **resolved** — step 7b; `BootManifest.Planned` exposed and specced | Medium | Main / BootManifest | 2 | `Tests/Boot/BootManifest.spec.lua` "planned Systems are honestly planned" |
| L-6 | `GameplayEvents` PlayerKilled prose + subscriber inventory named deleted CombatSystem, omitted Blimp/Boat/Emote | `GameplayEvents.lua:57-63, 96-122` | **resolved** | Low (misleading) | GameplayEvents | 1 | read |
| L-7 | Stale CombatSystem prose in touched files (RespawnSystem Init, Constants.Meridian/Respawn, BloodlineTypes, BloodlineSystem header, MeridianSystem header) | as named | **resolved** | Low | each file | 1–2 | read |
| L-8 | BloodlineSystem still subscribes to PlayerKilled directly for stage-ups | `BloodlineSystem.lua:647` | **resolved 2026-10-06** — `BloodlineStage` component → `BloodlineSystem.CountKill`, subscription deleted | Medium — a second progression path outside the gate | BloodlineSystem → ProgressionSystem route | next | header updated with migration condition |
| L-9 | BountySystem pays Meridian XP directly on claim | `BountySystem.lua:276` | **resolved 2026-10-06** — `BountyClaim` component → `BountySystem.PayClaim` (weighted) | Medium — reward outside the manifest | RewardSystem (a `BountyClaim` component) | next | — |
| L-10 | `RivalrySystem.Init` is not idempotent (subscribes PlayerKilled each call); its spec calls Init repeatedly | `RivalrySystem.lua:195-200`, `Tests/Progression/RivalrySystem.spec.lua:9` | **resolved 2026-10-06** — Init cleans a Trove of its previous subscriptions first | Low in prod (one Init), leaks subscriptions in the test VM | RivalrySystem | later | read |
| L-11 | 2026-08-19 audit §3 lists Bloodline/BloodlineManager/QiDeviation as stubs | `2026-08-19-audit.md:183-188` vs real bodies | **stale** | Low (misleads triage) | this doc | — | `wc -l`, bodies read |
| L-12 | `software-architecture.md` described a monolithic CombatSystem and Constants/Types-first layout | `docs/software-architecture.md` | **resolved** — rewritten against source | Medium | docs | 3 | read |
| L-13 | Six planned Systems are empty and required only by `Main.server.lua` | Faction/Achievement/Absorb/Awakening/Territory/World | **open (by decision)** — kept, now spec-guarded as Init-only | Low | roadmap | 3 | inbound-require grep: `Main.server.lua` only |
| L-14 | Remote surface: rate limiting / RemoteHandler | 24 files with `OnServer*` | **negative** — every handler rate-limited; every RemoteFunction wrapped (ServerHop exemption intact) | — | — | 0 | per-file grep counts |
| L-15 | Player-keyed tables without lifecycle cleanup | 30 `{ [Player]: … }` tables | **negative** (heuristic: each has a clear/nil path) | — | — | 0 | grep |
| L-16 | Client requiring server modules | `StarterPlayer/`, `Shared/` | **negative** | — | — | 0 | grep (comment hits only) |
| L-17 | ParkourSystem/RunSystem own raw `RunService.Heartbeat` rather than `OnHeartbeatTick` | `ParkourSystem.lua:412`, `RunSystem.lua:625` | **open** | Low (two connections) | each | later | read; not touched |
| L-18 | UISettings type added to `Shared/Types.lua` (user WIP) | `Types.lua` diff | **open (informational)** — consistent with the existing settings family there; a Settings domain types module is the eventual home | Low | Settings | later | `git diff` |
| L-19 | 207 `CombatSystem` mentions across 62 files | `grep -rn CombatSystem src` | **open** — correct on touch only, no sweep | Low | — | ongoing | grep |
| L-20 | Unused `Reveal` require (user WIP) | `Client/UI/Screens/HUD/init.lua:104` | **new** — only selene warning in tree | Trivial | HUD | owner | `selene src/` |
| L-21 | 12 failing specs, all in uncommitted weapon/audio WIP (default weapon now "Fists"; a bare `rbxassetid://` SoundId) | `WeaponInventorySystem.spec`, `SwingSequencer.spec:366`, `AssetPreloader.spec:103` | **new, not introduced here** | Medium for that WIP | owner | owner | identical before/after this change; files untouched |

## 4. Open items, in implementation order

1. **O-1 Bloodline onto the spine (L-8).** Add a `BloodlineStage` component to the taxonomy, a route to a
   public `BloodlineSystem` advance call, and delete its direct subscription in the same change.
   *Blocked on product:* confirm stage advancement should obey the same gate as XP (it will, once routed).
2. **O-2 Anti-farming (ProgressionSystem gate).** Repeat-victim rule landed (L-24). Still open: alt
   detection, cross-server history, tier-gap scaling -- *product/balance decisions*.
3. **O-3 Bounty payout as a manifest component (L-9).** Needs a decision on whether a claim is a separate
   reward kind or a Meridian XP modifier.
4. **O-4 Absorb.** Needs the absorb balance design before a component can exist.
5. **O-5 RivalrySystem idempotent Init (L-10).** Safe, local; the Bounty pattern (`BountySystem.lua:414-430`).
6. **O-6 Roadmap stubs (L-13).** Move the six into roadmap docs and out of production boot once someone
   confirms none is about to gain a body; the spec now fails the day one grows an API without moving.

## 4b. Follow-up pass, same day: feedback, farming, knockback

| # | Item | Citation | Status | Evidence |
|---|---|---|---|---|
| L-22 | Death overlay and kill feed had no producer since the combat rewrite | `PlayerDeathSystem` Death_Notice broadcast; `Client/Combat/DeathNoticeClient.lua`; `Screens/DeathFeed` `PushKill` | **resolved** | `Tests/Progression/DeathNotice.spec.lua`, `Tests/UI/KillFeed.spec.lua` |
| L-23 | Killer got no readable "+XP" | `MeridianXPUpdatePayload.Gained/Reason` → `ClientState.MeridianXPGain` → TierBadge readout | **resolved** | playtest only (render) |
| L-24 (O-2) | Kill farming: same pair could trade kills for full XP forever | `ProgressionSystem` repeat-victim rule, `ProgressionConstants.RepeatVictim` (runs keyed by UserId; 1 / 0.5 / 0.25 / 0 inside a 10-min run) | **resolved for Meridian XP**; Bounty payouts and Bloodline stage-ups joined 2026-10-06 (`Tests/Progression/SpineRoutes.spec.lua`). Bounty *streaks* still count every kill, by design: a mark is a social fact, not progression | `Tests/Progression/KillFarming.spec.lua` |
| L-25 | Authored knockback resolved but applied by nothing | `Shared/Damage/Knockback.lua`, `DamageSystem` (`DamageResult.Launch`, server-owned bodies), `Client/Combat/KnockbackClient.lua` (players, after hit-stop) | **resolved** | `Tests/Combat/Damage/Knockback.spec.lua` |
| L-26 | Honest knockback could count toward the parkour cheater flag | `Attributes.KnockbackUntil` + `ParkourSystem.noteRejection` | **resolved** | read |
| L-27 | A client could ignore knockback undetected | `Server/Combat/Damage/KnockbackAudit.lua` (samples replicated velocity; flags after 6 failures / 120 s) | **resolved (detector)** | same spec |
| L-28 | Knockback lost while a parkour VELOCITY action owns the body (ParkourMotor overwrites it next frame); RagdollSeconds/StartsAirCombo authored but inert | `KnockbackClient`, `MoveTypes.MoveKnockback` | **open** | combat tag gates most parkour actions mid-fight, so rare |
| L-29 | Repeat-victim history does not survive a server hop; no alt-account detection | `ProgressionSystem` | **open** | — |

Player-visible changes from this pass: a death card with the killer's name and a countdown, a kill
feed (attributed kills only), "+N" on the TierBadge per grant, reduced/zero XP for repeat kills of the
same victim, and every move with authored knockback now actually launches. Knockback tuning values
(`DamageConstants.Knockback`, `ProgressionConstants.RepeatVictim`) are starting points, not derived.

## 5. Behaviour that changes for players

Because kills are now attributed, four existing consumers fire for the first time in the rebuilt
combat era: Meridian XP per kill (→ tier-ups), Bounty streaks/marks/claims, Rivalry standings, and
Bloodline stage advancement. All were written and specced against attributed kills; none has had a
live playtest with them. A two-client playtest of a kill, a knock-off death and a respawn is the
remaining verification this pass cannot do headless (the `Players:GetPlayerFromCharacter` adapter lines
and the real `Humanoid.Died` wiring).

## 6. Verification

- `selene src/` — 0 errors, 1 warning (L-20, not in a touched file).
- `stylua --check` on every touched file (CRLF files checked via LF-normalised stdin) — clean.
- Focused TestEZ run (`Tests/Progression`, `Tests/Boot`, `Tests/Combat/Damage`) — **336/336 passed**.
- Full suite — see the change report for the exact count; the only failures are L-21.

Docs are revised in the same change as the architecture they describe — see
[`software-architecture.md`](../software-architecture.md).

## 7. Follow-up, 2026-10-06: O-1 and O-3 closed

- **O-1 Bloodline.** The kill's manifest carries a `BloodlineStage` component, and ProgressionSystem routes it
  to `BloodlineSystem.CountKill(killer, weight)`. The direct subscription is deleted. The weight counts as a
  fraction of a kill, so a second kill of the same victim inside the repeat window is half a kill toward the
  next stage. The audit marked this as needing a product call: stage-ups now obey the same gate as XP. That
  matches the fight-to-grow pillar, and reverting is one taxonomy entry.
- **O-3 Bounty.** Answered as a separate reward kind (`BountyClaim`), not an XP modifier, because the
  bounty owns its own amount. The mark stays on BountySystem's own subscription, since an unattributed
  death must end a run too. The payout rides the spine. The two subscribers have no defined order, so the
  claim is resolved by whichever hears the death first and keyed by `deathId` (`BountySystem.owedByDeath`;
  an owed claim the gate refused lapses after `BountyConstants.OwedClaimSeconds`).
- **O-5 Rivalry.** `RivalrySystem.Init` is idempotent (a Trove of its subscriptions, cleaned first).
- Not runnable here: the TestEZ suite. `Tests/Progression/SpineRoutes.spec.lua` covers both orders, the
  weighting and the zero-weight refusal.
