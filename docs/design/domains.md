# Domains (Unfurlings) — design and implementation

*Added 2026-09-30.* The framework for an ultimate that turns the ground around its caster into a temporary
combat realm with its own law. The framework supplies the mechanics; each domain's identity is data,
authored in the Move Editor's **Domain** tab. There is no domain named anywhere in code.

## What it is, in the world

An **Unfurling**. A cultivator turns their own Meridian Particle inside out and, for a few seconds, the
ground around them runs on their meridian's law instead of the world's — a fragment of the unified
Meridian the Shattering broke, restored under one person's will (`world-bible.md`, The Meridian Particle).
That is why it is the rarest, most expensive thing a fighter can do, and why two of them meeting is a
contest of wills rather than a damage race. Code calls it a *domain* or *realm*; players should see
*Unfurling*.

## What it is, in the code: a move

A domain is **a move carrying a `Domain` block** (`MoveDefinition.Domain`, schema in
`Shared/Domain/DomainTypes.lua`) — the same rule that makes an art a move with an `Art` binding and a
projectile move a move with a `Projectile` block. So the whole activation sequence needs nothing of its own:

| The request asked for | Where it comes from |
|---|---|
| Activation animation | the move's clip (`AnimationId`), synced like any move's |
| Tell / windup | the move's windup, heavy tell and all |
| Cooldown | the move's `Cooldown`, enforced by `AttackRequestSystem` |
| Resource cost | the art binding's `QiCost`, charged by `ArtSystem` when the swing is accepted; plus the block's own `UpkeepQiPerSecond` while the realm holds |
| VFX / SFX | the move's `Presentation` block — four new moments (`DomainOpen`, `DomainActive`, `DomainPulse`, `DomainClose`) in `MovePresentationTypes`, edited on the existing Presentation tab |
| Name / description | the move's own |

When `AttackRequestSystem` accepts a domain move's swing, `DomainSystem` hears it on `OnSwingAccepted`
(the documented "a swing started" extension point) and **pends** the cast. The realm is the move's extension,
not the move: it opens when the move's own windup (`WindupSeconds`) has run out, and its clock -- the unfurl,
the centre, the owner's pose -- starts at that scheduled instant. A swing cut before then (feint, parry, stun)
or an owner who dies in the windup means the realm never exists.

## Lifecycle

`Idle → Activating → Active → Ending → Finished` (`Server/Combat/Domain/DomainInstance.lua`).

- **Activating** (`ActivationSeconds`): begins when the move's windup ends. The boundary unfurls; nobody is
  governed, nothing fires; the owner is exposed. It collapses if the owner is struck (`CancelOnOwnerHit`) or
  dies. (The swing being cut is a windup matter: the realm has not opened yet, so there is nothing to collapse.)
- **Active** (`ActiveSeconds`): founding membership (everyone inside, nearest first, up to `MaxTargets`), the
  wall if any, rules, effects, clashes, boundary enforcement, Qi upkeep.
- **Ending** (`EndSeconds`): the law lifts at once (every rule attribute cleared); only the visual folds.
- **Finished**: record torn down, owner's one-realm lease cleared.

Phases end at their scheduled time, not the frame that noticed (a hitch never stretches a realm). Every
runtime instance has a unique id (`D1`, `D2`, …) and tracks owner, times, centre, radius, members, effect
timers, clash state and erosion (`DomainSystem.Get(id)` returns a snapshot).

## Boundary

Server-owned geometry (`Shared/Domain/DomainGeometry.lua`) — the same math drives the server's enforcement,
the projectile barrier and the owning client's predicted wall. Shape `Sphere | Cylinder | Box`, `Radius`,
`Height`, anchored `Fixed` or `FollowOwner`, centred `CenterForward` studs along the caster's facing.

| Option | Behaviour |
|---|---|
| `EntryRule = Barred` | anyone not inside at establishment is repelled (set back outside, predicted client-side) |
| `ExitRule = Barred` | founding/admitted members are held in (set back inside, predicted client-side). The owner is never held |
| `EntryGraceSeconds` | a newcomer stands inside this long before any effect targets them |
| `ExitLingerSeconds` | a leaver keeps the realm's rules this long |
| `BoundaryCollision` | a physical wall to every body, both ways (fixed realms only) — the sealed realm |
| `ProjectilesEnter / Leave` | off = shots crossing that way stop at the edge (`HitboxEngine.SetProjectileBarrier`). The realm's own strikes are exempt |
| `CancelOnOwnerExit` | the owner leaving their own fixed realm collapses it |
| `Interacts` | off = other realms ignore it and it ignores them |

## Effects (periodic, "sure-hit")

Up to 6 per realm, each on its own interval, targeting a filter of members (`Allegiance.lua`: Enemies,
Allies, Owner, Owner and allies, Everyone but owner, Everyone; and Players / Bots-and-dummies / Any), nearest
first, `MaxPerPulse` per pulse. Every kind goes through an entry point that already existed:

| Kind | Delivered through |
|---|---|
| **Strike** | the referenced move, as one homing shot pinned to that body (`HitboxEngine.LaunchVolley`, exclusive — nobody in the line is touched). DefenseSystem still decides block/parry/evade (`Parryable` off → `CannotParry`; a parry *destroys* the strike, never staggers a far-off owner); DamageSystem prices it **as that move, flat** (no combo escalation). Kill credit, combat tagging and hit cues follow for free. `TravelSeconds` is the target's read window |
| **Volley** | a projectile move's own volley, aimed at each target from the realm (its spread, pierce and parry answers apply) |
| **Hitstun** | `DamageSystem.ExtendHitstun` (capped at `DomainConstants.MaxHitstunSeconds`) |
| **GuardDrain** | `DefenseSystem.DrainGuard` |
| **Pull / Push** | the knockback owner split: a player's own client applies it (`KnockbackClient.Push`), a bot's body is set server-side |
| **OwnerCast** | the owner throws the referenced move through `AttackRequestSystem.ThrowMove`, every gate included |

"Sure-hit" here means *guaranteed delivery*, not *undefendable*: spacing cannot dodge a strike, but the
defensive layer still answers it unless the author spends the realm's budget on `Parryable = false` or a
`NoBlock`/`NoParry` rule. That keeps `combat-philosophy.md` principle 3 ("no true unblockable without an
explicit, telegraphed cost") — the cost is the ultimate itself: a long activation the owner can be struck
out of, the cooldown, the Qi, and the upkeep feeding Qi Deviation risk.

## Rules (continuous)

Up to 10, each on a filter. Published as **Humanoid Attributes** on each governed body
(`Shared/Domain/DomainRules.lua`) and read by the layer that already owns that question — no combat layer
requires `DomainSystem`:

| Rule | Read by |
|---|---|
| DamageDealt / DamageTaken / GuardDamageTaken / HitstunTaken (×) | `DamageSystem.applyOutcome` |
| NoBlock / NoParry | `DefenseSystem` pass 1 |
| NoEvade | `DefenseSystem.BeginEvade`, `ParkourSystem` |
| Cooldown (×), SealMove, SealArts, SealProjectiles, SealDomains | `AttackRequestSystem.throw` (refusal `DomainSealed`, not buffered) |
| MoveSpeed (×), Rooted | `RunSystem` |
| NoParkour | `ParkourSystem` + the client's combat gate (`ParkourConstants.DomainGate`) |

Every rule is read through `DomainUntil` — the governing realm's scheduled end on the shared server clock —
so a set the runtime failed to clear still lapses when the realm was always going to end. Several realms
governing one body compose: scales multiply, flags OR, seals union.

## Clashes

Resolved when two established realms' bounds first overlap (`Shared/Domain/DomainClash.lua`): higher
`Priority` wins; a tie goes to the later realm's `TieBreak` (`Older` yields, `Newer` claims, `Contest`
refuses to decide). The **winner's** behaviour toward the loser — its per-opponent `ClashOverrides` entry
(keyed by the other realm's MoveId) or its default:

| Behaviour | Effect |
|---|---|
| Coexist | both laws apply to anyone in both |
| Suppress | in the overlap only the winner's law and effects apply |
| Erode | Suppress, and the loser's time drains at the winner's `ErodeRate` per second of overlap |
| Dominate | the loser collapses |
| Shatter | both collapse |
| (Contest) | both apply in the overlap, each scaled by its own `ContestScale` (effects' magnitude and strike damage, and rule scales pulled toward 1) |

## Performance and authority

One Heartbeat for every realm. Per frame: owner checks, phase boundaries, effect deadlines (a few
comparisons per realm). At 10 Hz: membership (a distance test per realm per *registered combatant* — the
`Combatant` tag's set, tracked by its signals, never a world search), barred edges, clashes, upkeep, and the
law republished only where it changed. No per-target connections; no server with no realm pays anything
but a length check. The server owns creation, state, membership, effects, duration, clashes and every
consequence; clients receive `Domain_State` (Open/Phase/Clash/Pulse/Snapshot, and their own Impulse) and
draw — `Client/FX/DomainFX.lua` renders the shell (it *is* the boundary), the screen grade under a realm's
law (from the server's `DomainGovernor` attribute, never local geometry), the cues, and the predicted wall.

## Files

| Piece | File |
|---|---|
| Schema, limits, validation, wire types | `Shared/Domain/DomainTypes.lua` |
| Tuning, remotes | `Shared/Domain/DomainConstants.lua` |
| Geometry | `Shared/Domain/DomainGeometry.lua` |
| Rule seam (attributes) | `Shared/Domain/DomainRules.lua`, `AttributeConstants.Domain*` |
| Clash arbitration | `Shared/Domain/DomainClash.lua` |
| Allegiance / target filters | `Shared/Combat/Allegiance.lua` |
| Runtime | `Server/Combat/Domain/DomainSystem.lua` (+ `DomainInstance`, `DomainEffects`, `DomainWall`) |
| Engine seam | `HitboxEngine.LaunchVolley`, `HitboxEngine.SetProjectileBarrier` (`ProjectileSimulator.LaunchAimed`/`SetBarrier`) |
| Client | `Client/FX/DomainFX.lua`, `FXConstants.Domain` |
| Editor | `Client/UI/Screens/DevTools/MoveEditor/DomainTab.lua` |
| Specs | `Tests/Domain/*`, `Tests/Combat/Domain/*`, `MoveRegistryManager.spec` |

## Known limits and follow-ups

- **No party/team system exists**, so "Allies" today means players on the same Roblox `Team`
  (`Allegiance.AreAllies` is the one function a future sect/party system changes).
- `MoveSpeed`/`Rooted` govern **players** only (RunSystem owns player WalkSpeed); a training bot's own
  movement ignores them. Bots also do not react to realms at all yet.
- The Evade *glide* is client-predicted; under `NoEvade` the server refuses the evade frames and the report,
  so a client that skips its gate glides without invulnerability.
- The player-facing HUD shows the realm (shell + grade) but has no text banner yet.
- No authored realm ships yet — author one in the Move Editor (Domain tab), bind it to an art tree to put it
  on a hotbar.
