# Move Editor overhaul -- handoff (2026-10-01)

**Branch:** `constants-split`. **Status:** PARTIALLY DONE -- the engine/domain half and the editor's low-level
primitives are built and specced; the editor's tab restructure (the "much better area sectioning" half) is NOT
started beyond primitives. Read "What is done", "What is NOT done" and "Verification" before touching anything.
Per CLAUDE.md: re-verify any line against current source before depending on it.

## What the owner asked for (verbatim)

> add alot more shapes and sizes to the hitboxes and weapon shapes that we are allowed to have for projectiles,
> improve the move editor with much better area sectioning, there are many switches and settings that should be
> in a panel and they are in some completely other one that doesnt really have relevance to that section,
> improve on the domain expansion support in the move editor, when a move is selected as a domain expansion only
> show settings related to domain expansions and have their own way to use the attack resolver without spawning a
> hitbox infront of the player before the move, however make sure that the moves still act as a move, allow me to
> keep everything i can do right now like changing the animations and and other things like that, that already
> exists however the domain expansion feels as its own thing while it uses the proper pipelines, improve on the
> settings sliders and sectioning, make sure it is all performative and modern

Breaking that into requirements:
1. More hitbox shapes **and sizes** (melee), and more shapes/sizes for the **projectile body** ("weapon shapes").
2. Editor: better **area sectioning**; move settings that live in an unrelated tab to the tab they belong to.
3. Domain expansion in the editor: when a move is a domain, show **only domain settings**; domain gets its **own way
   to use the attack resolver**, with **no hitbox spawned in front of the player** during the cast.
4. A domain move must **still act as a move** (clip/animation, windup, cooldown, art binding, presentation, undo,
   save, test swing... all keep working).
5. Better **sliders** and sectioning; **performant** and **modern**.

## What is DONE (all in the working tree / PR)

### Engine -- shapes (`Shared/HitboxEngine`)
- `HitboxTypes`: `ShapeKind` 7 -> **15**: added `Ellipsoid, Hemisphere, Frustum, Pyramid, Wedge, Crescent, Cross,
  Pillar`. `SHAPE_FIELDS` says which Dimensions each reads (Crescent: Radius/InnerRadius/Length=bite offset/Height;
  Cross: Width/Length/Height + Radius=bar half-thickness; Frustum: Radius far, InnerRadius near). New
  `HitboxTypes.ShapeOrder`, `ConventionOf`, `Presets` (14 named starting volumes: Fist, Jab, Thrust, Slash, Sweep,
  Spin, Cleave, Smash, Dome, Breath, Funnel, Lance, Burst, Egg) + `PresetById`.
  `AttackDefinition.Volumeless` added (see Domain).
- `HitboxGeometry`: `BoundingBox`, `Reach`, `MinExtent`, `ContainsPoint` for all new shapes.
- `MoveTypes.Shapes = HitboxTypes.ShapeOrder`. `EditorConstants.Limits.Dimensions` widened (W/H 60, L 80, R/Inner 40).
- Projectile bodies: `ProjectileTypes` gained `Shape` (Sphere default + Capsule, Ellipsoid, Cylinder, Box, Cone,
  Pyramid, Wedge, Frustum, Crescent, Cross, Pillar) and `Length, Width, Height, InnerRadius, AngleDegrees`; `Size`
  stays the radius (max 16 -> 24). Old records validate to Sphere unchanged. 14 weapon `Presets` (Orb, Fireball,
  Arrow, Spear, Kunai, Shuriken, SwordWave, Cutter, Boulder, Log, Wall, Drill, Blade, Tide).
- NEW `Shared/HitboxEngine/ProjectileBody.lua` (pure): `Of(spec)`, `PoseAt` (reach shapes fly point-first),
  `Look` (client part type/size). `ProjectileSimulator` sweeps non-sphere bodies with `SweptContainsPoint`
  (bounding-sphere broadphase; world Spherecast from the body's leading edge); sphere keeps its old fast path.
  Launch events carry `Body` only for non-spheres (`AttackTypes.ProjectileWireEvent.Body`). `ProjectileFX` draws
  shaped bodies (Cylinder / bounding Block laid along the flight).
- Editor visuals: `HitboxPreviewShapes` (world preview parts for all 15), `PlacementMath` (resize handles for new
  shapes), `HitboxPlot` (rasterises `ContainsPoint` so new shapes just work; now only visits cells each volume
  covers and only writes changed cells; draws projectile bodies along the volley path),
  `HitboxWorldPreview` (projectile spawn body, domain realm boundary preview).

### Domain
- `AttackDefinition.Volumeless`; `MoveTypes.ToEngineAttackDefinition` sets it for any move with a `Domain` block;
  `HitboxEngine.beginActiveWindow` honours it (full swing lifecycle + movement locks, **no volume sampled**, so
  nothing spawns in front of the caster).
- **Realm's own strike:** a `Strike` effect with a blank `MoveId` is priced by the domain move itself (its Damage,
  PostureDamage, PowerLevel, Knockback via the normal `AttackCatalog` -> `DamageSystem` path). `DomainTypes`:
  `EffectNeedsMove = {Volley, OwnerCast}`, new `EffectMayUseOwnMove = {Strike}`, `EffectUsesPower`; a Strike naming
  its own id is normalised to blank. New effect field **`Power`** (0..5, default 1) multiplies Strike/Volley price.
  `DomainEffects.Source` gained `MoveId`; `DomainSystem` passes it.
- Domain + Projectile on one move is still *accepted* by Validate (old records); the editor is meant to make the
  types exclusive.

### Editor primitives (UI)
- `Components/NumericField`: opt-in **`Compact = true`** -- 2 lines (label/unit/value over steps+slider), full-row
  hit area slider with growing handle, values snapped to `Decimals`, gamepad DPad nudge, lightweight step buttons.
  Default layout and other callers untouched. **`Fields.Number` does not pass `Compact` yet.**
- `Components/ScreenFrame.NewTabState(scope, names, availability?)` + `Tab.Visible`: tabs can be hidden per move
  type; the strip shares space (flex fill) and re-selects the first available tab if the current one disappears.
  **Nothing uses `availability` yet.**
- `DomainTab`: Strike effects still show the Move id field (blank = realm's own) and a new Power field.

### Tests added/updated
`HitboxGeometry.spec` (new shapes + bounding-box/reach property checks), NEW `ProjectileBody.spec`,
`MoveTypes.spec` (15 shapes, presets, Volumeless), `DomainTypes.spec` (own strike, Power), `DomainStrike.spec`
(own strike, Power), `HitboxEngine.spec` (Volumeless), `Projectile.spec` (shaped bodies, wall tip, wire Body).

## What is NOT done (the remaining plan)

The editor restructure -- task #3. Intended design (nothing below exists yet):
1. **Move type bar** above the form pages (custom moves only): `Melee | Projectile | Domain Expansion` segmented
   control. Setting a type clears the others' blocks (Domain: `Domain = DomainTypes.Defaults()`, `Grab=nil`,
   `Projectile=nil`; Projectile: seed `ProjectileTypes.Defaults()`, `Grab=nil`, `Domain=nil`; Melee: both nil).
2. **Dynamic tabs** via the new `availability`:
   - Melee/Projectile: `Hitbox, Timing, Impact, Presentation, Identity, Tools`.
   - Domain: `Realm, Boundary, Effects, Law, Clash, Timing, Presentation, Identity, Tools` (no Hitbox, no Impact).
   - Update `Copy.lua` failure->`Tab` mapping (the old `"Domain"` tab goes away; `MoveEditorClient` does
     `handle.CurrentTab:set(failure.Tab)`), and `Copy.Presentation` text that says "Hitbox tab"/"Domain tab".
3. **Relocate misplaced settings:** "Lock movement while winding up/active" (Hitbox tab) -> Timing `COMMITMENT`
   with Feintable; Power level (Timing) -> Impact `COST`; the Domain tab's duplicated Name/Description/Cooldown ->
   they already live in Identity/Timing (domain mode just shows them where relevant).
4. **Sections:** new `Fields.Section` (foldable heading + summary text + *lazily built* body), `Fields.Lazy`,
   lazy pages (build on first visit), `Fields.Chips` (wrapping chip group -- for the 15 shapes and the preset
   "Start from" rows; a Dropdown of 15 would expand 600px), `Fields.Segmented`. Domain effect/rule/override slots
   built only when the slot first exists (today all 6+10+6 slots' fields are mounted up front: ~300 fields).
5. **Hitbox tab content:** presets + shape chips + only the dimensions the shape reads (per-shape label overrides,
   e.g. Cross Radius = "Bar half-width"), a "scale volume x0.5/x0.8/x1.25/x2" row; projectile `BODY` group (weapon
   preset chips, shape chips, measurements), then Volley / Flight / Homing / Collision / Parry / Spawn.
   Domain `Boundary` tab hosts "Show on my character" (realm preview already supported by `HitboxWorldPreview`).
6. **Domain Effects tab** gets a `STRIKE PRICE` section (Damage, Posture, Power level, Knockback) -- the realm's own
   strike price -- and `NumericField.Hint` should become `UsedAs<string>` so domain-mode hints can differ.
7. Switch `Fields.Number` to `Compact = true`; update `Tests/UI` specs (`ScreenFrame.spec` for availability).
8. Docs: update `docs/design/move-editor-guide.md` and CLAUDE.md shared-module table (ProjectileBody, Compact
   NumericField, tab availability) when the above lands.

Also open: in-engine specs (`HitboxEngine`, `Projectile`, `DomainStrike`, UI specs) were written but **could not
be run** here; `Packages/`+`DevPackages/` (wally) are absent and `run-in-roblox` needs Studio.

## Verification state

- Ran headless (Lune): `HitboxGeometry.spec` 54/54, `ProjectileBody.spec` 17/17, `DomainTypes.spec` 18/18,
  `MoveTypes.spec` 27/29 -- the 2 failures are **pre-existing at HEAD** (`Validate(ToWire(x))` returns
  `InvalidAuthor`; ToWire omits Author) and unrelated.
- `stylua` clean on touched files; `luau-analyze` finds no syntax errors in touched files.
- **`selene` NOT run** (needs `selene generate-roblox-std`, which fetches the Roblox API dump -- blocked here).
  Run `selene src/` and the full TestEZ suite in Studio before merging.
- Tooling used (downloaded to a scratch dir, not committed): luau, stylua 2.5.2, lune 0.10.4, rojo, selene 0.27.1.
  `scripts/dev/lune-spec-harness.luau` is the headless runner (pure modules only).
