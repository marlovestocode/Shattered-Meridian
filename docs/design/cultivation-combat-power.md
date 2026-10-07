# Cultivation power in combat

**Date:** 2026-10-06 · **Status:** built, **off** (`CombatPowerConstants.Enabled = false`)

## What it does

When it is on, the cultivation tier gap between attacker and defender scales a hit's health damage
and posture (guard) drain. Two fighters of the same tier are unchanged at every tier. Hitstun is
never scaled.

| Tier gap | Stronger side deals | Weaker side deals | Effective edge |
|---|---|---|---|
| 0 | 1.00x | 1.00x | none |
| 1 | 1.08x | 0.93x | 1.17x |
| 2 | 1.17x | 0.86x | 1.36x |
| 3 | 1.26x | 0.79x | 1.59x |
| 4+ (cap) | 1.36x | 0.74x | 1.85x |

Posture uses a smaller rate: 5% per tier against 8% for damage. Pressure is the weaker fighter's
best tool for closing a gap (combat-philosophy.md, "Posture meter").

## Why these choices

- **A gap, not a stat.** Everyone climbs the ladder, so an absolute per-tier bonus would only shorten
  fights at the top. The design rule is relative: execution decides fights inside a tier, the better
  player can win across a one-tier gap, and a multi-tier gap is very hard but not impossible. The
  only input is attacker tier minus defender tier.
- **The cap keeps "not impossible" true.** A tier 9 against a tier 1 counts as a gap of 4.
- **Stun stays fixed.** The M1 string's stun is derived from the animation timeline so that the next
  hit lands inside it. Scaling stun by power would make strings drop against stronger players and
  loop forever against weaker ones.
- **A body with no tier is neutral.** Training bots, dummies and players whose profile has not loaded
  yet have no gap with anyone. They are never treated as tier 1.

## How it is wired

```
TierSystem ── Player Attribute "CultivationTier" (on profile load and on promotion)
                    │
Shared/Progression/CombatPower.lua  ── TierOf / TierGap / Scales
                    │
DamageSystem.applyOutcome, DamageSystem.ApplyImpact
                    │
DamageResolver.ApplyScales: base → shot → power → realm
```

- **No combat layer requires TierSystem.** The tier crosses as a replicated Attribute, which is the
  same seam realms use (`DomainRules`). Opponents' clients can read it too, so a tier can later be
  shown on nameplates, matching the "readable power" pillar.
- **The Live Console shows the gap.** `CombatTrace`'s "Applied" line carries `tierGap` when power is
  on and the two fighters' tiers differ.
- **Staging a gap without a second account.** In Studio, set a `CultivationTier` Attribute (1–9)
  directly on a training bot's or dummy's Model.

## Turning it on

1. Set `CombatPowerConstants.Enabled = true`.
2. Playtest a 1-tier and a 3-tier gap against a training bot, using the staging step above.
3. Tune `DamagePerTier`, `GuardPerTier` and `MaxTierGap`. `Tests/Progression/CombatPower.spec.lua`
   fails if a one-tier gap reaches an edge of 1.25x or more. That limit is the design rule above
   written as a test, so move it only deliberately.

## Not covered here

Bloodline stages and arts are not power sources here. combat-philosophy.md asks that they add
decisions to a kit, not just numbers. If one does end up as a scale, it is composed inside
`CombatPower.Scales`, so that `DamageSystem` still reads only one pair of numbers.
