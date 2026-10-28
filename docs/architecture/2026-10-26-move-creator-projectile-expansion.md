# Move Creator projectile expansion (2026-10-26)

What the Move Editor could already author, what it could not, and the extension that closes the gap. Read
`ProjectileTypes.lua`'s header for the field-by-field meaning; this file is the reasoning.

## 1. What exists (traced, not assumed)

The path an editor control takes to a shot in the world:

```
HitboxTab (Fusion form)  -> draft.Projectile[field] = value
  -> MoveTypes.ToWire (ProjectileTypes.Copy)        -> MoveEditor remote
  -> MoveRegistryManager.Validate (ProjectileTypes.Validate: type-strict, clamp numbers, absent = default)
  -> MoveRecordCodec (v3 pass-through)               -> DataStore / Server/Combat/AuthoredMoves source
  -> MoveTypes.ToEngineAttackDefinition (Copy)       -> HitboxTypes.SanitizeDefinition
  -> AttackRequestSystem.Throw -> HitboxEngine.RequestAttack
  -> AttackStateMachine Active -> beginActiveWindow -> ProjectileSimulator.Launch
  -> ProjectileSimulator.Step (inside the engine's substep loop) -> emitHit -> DefenseSystem -> DamageSystem
  -> ProjectileSimulator events -> HitboxEngine.OnProjectileEvents -> ProjectileRelevance -> Attack_Projectile
  -> ProjectileFX (flies the visual with the SAME ProjectileMotion.Integrate)
Editor plot: HitboxPlot -> ProjectileMotion.Volley / Path (the same math again).
```

The load-bearing property: **`ProjectileTypes.Fields` is the schema**. Copy, wire, Validate, the engine
sanitiser and the record codec all walk it, so a field added there is carried end to end with no second
list to update. Every move saved before a field existed loads with that field's default.

Already authorable: 12 body shapes + 14 body presets; Single/Fan/Row/Column/Ring(radial) volleys; speed,
lifetime, range (path length), gravity, acceleration; piercing, wall Destroy/Bounce/Continue; homing
(strength, cone, range, Nearest/Aim selection); fire direction Facing/Anchor/Target; parry
ParryOne/ParryAll/CannotParry with ExistingParry/Destroy/Reflect/Reverse; per-moment presentation cues.

The surrounding move (windup/active/recovery synced to the clip, locks, cooldown, feint, damage, stun,
knockback, presentation cues) is already authored on the Timing/Impact/Presentation tabs and is the
"phase" model a move has. It does not need a second one.

## 2. What was missing, and the decision for each

| Gap | Decision |
|---|---|
| One volley per cast; no waves, no sequential fire | `WaveCount`, `WaveIntervalSeconds`, `ShotIntervalSeconds` (stagger inside a wave), `WaveRollDegrees` (spirals), `WaveAim` Follow/Fixed, `AlternateSides` (dual-wield: even waves from the other hand, offset mirrored). Pending launches live in the simulator, are owned by the thrower, and are dropped when the swing is INTERRUPTED (stun, parry, death, unregister) -- a swing that completes keeps its remaining waves |
| Formations limited to five | `Grid` (rows of `Columns`) and `Circle` (origins on a ring, flying parallel); `FormationRadius` (Circle's radius, and for Fan/Ring pushes each origin out along its own heading -- surrounding emitters); `ConvergeDistance` (every shot re-aimed through one point ahead) |
| Spawn only from the thrower | `SpawnFrom` Anchor/Target: the move's offset applied in a frame at the target (right/up/forward relative to the thrower->target line) -- "above the target". Target picked server-side by the same selection homing uses |
| Range only along the path | `RangeMode` Path/Displacement |
| Speed only clamped to the global cap | `MinSpeed`, `MaxSpeed` (in the replicated Motion) |
| Straight/ballistic/homing only | `WeaveDegrees`/`WeaveFrequency`/`WeavePlane`/`WeaveMirrored` (sine weave, exact per age so client and server agree at any step size); `ReturnAfterSeconds`/`ReturnTurnRate` (boomerang, ends "Returned" at the thrower) |
| Homing all-or-nothing | `HomingDelaySeconds`, `HomingDurationSeconds`, `LeadTarget` (intercept aim for "At target") |
| One hit per target, no splash, no falloff | `RehitSeconds`, `ProximityRadius` (detonates near a body), `FalloffStartStuds`/`FalloffMinScale`, `ExplodeOn`/`ExplosionRadius`/`ExplosionDamageScale`/`ExplosionScope` |
| No follow-up on a shot's end | `SplitOn`/`SplitCount`/`SplitPattern`/`SplitAngle`/`SplitSpeedScale`/`SplitGenerations` |
| Presets only set the body | `ProjectileTypes.Recipes`: whole-behaviour starting points (Shotgun, Gatling, Boomerang, Cluster bomb, Spiral, Sky strike, Serpents, Lances, Mine) |
| Contradictions only noticed in play | `ProjectileTypes.Budget` (rejected over `MaxShotsPerCast` / `MaxCastSeconds` with a named error) and `ProjectileTypes.Warnings` (the editor's notes: settings that cannot take effect) |

### Deliberately NOT built

* **A generic action graph / visual scripting.** The engine's delivery is the projectile block, and every
  follow-up a shot can have is one of two bounded effects (explode, split) on a classified end reason.
  A graph would be a second move model beside MoveTypes, unsafe to run server-side, and the "Extend,
  migrate, never fork" rule forbids it without the user's go-ahead. Multi-stage moves remain strings and
  arts (existing machinery).
* **User-saved shared presets.** A preset other moves reference is shared mutable state that changes
  live moves behind their authors; Recipes are COPIED into a move and never referenced.
* **Orbiting-then-launch, mid-flight speed phases, per-projectile hand overrides inside one formation.**
  Each needs a per-shot state machine on the wire; deferred until a move needs one.

## 3. Runtime rules that keep it safe

* Everything is server-authored and server-run. The client sends nothing new; a target is always chosen by
  the simulator from registered combatants within the authored range and cone.
* End effects are DEFERRED one engine step, so the defence layer judges the contact first: an evaded shot
  is revived before it can explode, a parried (Destroy/ExistingParry) shot is defused. The shot's End event
  is sent with the effect (`End.Burst` carries the radius), so the router still holds its recipients.
* A blast is an ordinary projectile contact, unparryable (a parry window reads as a guard), sourced at the
  blast centre, skipping every body the shot already struck directly (no double hit), priced
  `DamageScale * ExplosionDamageScale` through the existing DamageScale passthrough.
* Splits copy the parent's hit set (a child never re-hits the body its parent just struck), share its
  GroupId (ParryAll answers the whole cast), and stop at `SplitGenerations` (<= 3). `Budget` bounds the total
  shots of one cast; `MaxLive` still bounds the server.
* Weave and homing gates are functions of the shot's AGE, which every Launch/Update now carries, so a
  client flying the visual between events integrates the same path.

## 4. Compatibility

Every new field has a default that reproduces the old behaviour exactly (one wave, no weave, no return,
Path range, MaxSpeed = the old global cap, no effects). No `SchemaVersion` bump: absent fields default
through `Validate`, the arrangement every earlier projectile field used. Existing Spread ids are unchanged
(Radial is relabelled "Cone" in the editor only).
