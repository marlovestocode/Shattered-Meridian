# Move Editor overhaul -- handoff (2026-10-01)

**Branch:** `constants-split`. **Status:** BUILT (2026-10-07) -- the engine/domain half (2026-10-01) and the editor
restructure (2026-10-07, "The editor restructure" below) are both in. What is left is a Studio pass: the full
TestEZ suite and opening the editor by hand (see "Verification"). Per CLAUDE.md: re-verify any line against
current source before depending on it.

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

## The editor restructure (DONE 2026-10-07)

Every step of the plan this section used to hold, as built. `Screens/DevTools/MoveEditor/init.lua`'s header is the
long version.

1. **Move type bar** (`init.lua`): `Melee | Projectile | Domain Expansion`, a `Fields.Segmented` above the pages,
   custom moves only. `MoveEditor.SetMoveType` IS the edit: Domain seeds `DomainTypes.Defaults()` (keeping one that
   is there), drops Projectile and Grab; Projectile likewise; Melee drops both. Re-picking the current type
   re-applies it, which is how an old record with a realm AND a grab is cleaned (`DomainCannotGrab` says so).
2. **Dynamic tabs**: one strip order (`Hitbox Realm Boundary Effects Law Clash Timing Impact Presentation Identity
   Tools`); `Realm..Clash` are offered while the draft has a Domain block, `Hitbox`/`Impact` while it does not.
   `Copy` points every realm refusal at Realm/Effects/Law/Clash, and a `Failure.DomainTab` (`Copy.FailureTab`)
   sends Damage/Knockback refusals to Effects for a realm. The driver uses it.
   - **ScreenFrame's availability mechanism was REPLACED.** As first built (2026-10-01) an Observer rewrote
     `Current` when it stopped being offered; that writes the Value its own Computed reads, and Fusion 0.3 refuses
     it at runtime (`Graph/change`: a "busy" dependent -> `infiniteLoop`) -- confirmed headless. Now `TabState.Shown`
     is a Computed (Current while offered, else the first offered tab) and `Selected` reads it; `Current` is never
     rewritten, so the author's tab comes back when the move changes back. The handle exposes it as `ShownTab`.
3. **Relocations**: the two movement locks left the Hitbox tab for Timing's new `COMMITMENT` section (with
   Feintable); Power level left Timing for Impact's `COST`; the old Domain tab's duplicated Name / Description /
   Cooldown are gone (Identity and Timing own them, and Timing's hints read as the cast's for a realm --
   `Copy.DomainTiming`, via `NumericField.Hint` now accepting a state object).
4. **Sections and laziness** (`Fields.lua`): `Fields.Section` (foldable heading, a live one-line summary opposite
   it, body built on first visible+open), `Fields.Lazy` (each page is built on its first visit), `Fields.Chips`,
   `Fields.ActionChips` (presets), `Fields.Segmented`, `Fields.ButtonRow`, `Fields.Pile`, `Fields.OptionsOf`. Realm
   effect / rule / override slots are a Section each, so a slot's fields are built only once the slot exists.
5. **Hitbox tab**: melee `VOLUME` (Start-from preset chips, 15 shape chips, only the dimensions the shape reads
   under that shape's own label -- `SHAPE_LABELS`, one field per distinct label -- and a x0.5/x0.8/x1.25/x2 scale
   row), `PLACEMENT`, `TARGETS`; projectile `BODY` (weapon preset chips, 12 body shape chips, measurements, scale
   row), `VOLLEY`, `FLIGHT`, `HOMING`, `COLLISION`, `PARRY`, `SPAWN`. Short closed choices are chips throughout.
6. **Domain pages** (`DomainTab.lua` now returns `Realm`, `Boundary`, `Effects`, `Law`, `Clash`): Boundary hosts
   "Show on my character"; Effects opens with `STRIKE PRICE` (Damage, Posture, Power level, Knockback -- the
   realm's own strike), built by the new `PriceFields.lua`, which the Impact tab mounts too.
7. `Fields.Number` passes `Compact = true` (every editor number is the compact slider). Specs: `ScreenFrame.spec`
   (availability / Shown), NEW `Tests/MoveEditor/MoveEditorScreen.spec.lua` (type helpers, tabs per type, the
   hand-over and back, lazy pages, lazy slots, every page of every type built, refusal routing).
8. Docs: `docs/design/move-editor-guide.md` (the screen, the type bar and tabs, sections, melee, projectile and
   domain sections), CLAUDE.md's shared-module table (ScreenFrame's Shown, compact NumericField, ProjectileBody).

Also fixed on the way: three `if_same_then_else` duplicate branches selene found in `HitboxGeometry`
(`BoundingBox`, `MinExtent`) from the 2026-10-01 shape work, merged with no change in behaviour (54/54 still).

## Verification state

As of 2026-10-07:
- **selene 0.31.0** (the version `aftman.toml` pins) on `src/`: **0 errors, 0 warnings, 0 parse errors.** (The
  2026-10-01 run used 0.27.1, which cannot parse some of this tree's syntax.) Generating the std needs the API
  dump; selene's prebuilt binary does not trust a TLS-inspecting proxy, so it was built from the crate with
  ureq's `native-certs` feature -- a local workaround, nothing in the repo changed for it.
- `stylua --check` clean on every touched file.
- **luau-lsp analyze** (Roblox definitions + rojo sourcemap, Fusion 0.3.0 from its own repo at the commit that
  published it) on every touched file: no new type errors -- the few left are on lines this change did not write
  (table-literal `Children` inference in `Fields.Pair`, `init.lua`'s Body row, `ScreenFrame` bands, NumericField's
  stacked layout), and the old `DomainTab`'s ten are gone.
- Headless (Lune, `scripts/dev/lune-spec-harness.luau`): `HitboxGeometry` 54/54, `ProjectileBody` 17/17,
  `DomainTypes` 18/18, `DomainClash`/`DomainGeometry`/`DomainRules` all pass, `ScreenFrame.spec` 12/12,
  **`MoveEditorScreen.spec` 12/12 with `--fake-dom`**, `MoveTypes` 27/29 (the 2 pre-existing `InvalidAuthor`
  failures, unchanged). The harness learned `Packages/` + `.luau` modules and an opt-in `--fake-dom` (a pure-Lua
  Instance tree with signals, for specs that mount Fusion UI -- structure only, no layout). `ScreenFrameScreens`
  under it mounts the Move Editor; its Settings and Dev Menu cases need Workspace/camera the harness does not
  model.
- **Still needs Studio:** the full TestEZ suite (`rojo build test.project.json` + `run-in-roblox`), and opening the
  editor -- nothing headless renders, so chip widths (estimated from text length), the section summary's
  truncation and the compact sliders' feel are unseen.

### Earlier (2026-10-01)

- Ran headless (Lune): `HitboxGeometry.spec` 54/54, `ProjectileBody.spec` 17/17, `DomainTypes.spec` 18/18,
  `MoveTypes.spec` 27/29 -- the 2 failures are **pre-existing at HEAD** (`Validate(ToWire(x))` returns
  `InvalidAuthor`; ToWire omits Author) and unrelated.
- `stylua` clean on touched files; `luau-analyze` finds no syntax errors in touched files.
- **`selene` NOT run** (needs `selene generate-roblox-std`, which fetches the Roblox API dump -- blocked here).
  Run `selene src/` and the full TestEZ suite in Studio before merging.
- Tooling used (downloaded to a scratch dir, not committed): luau, stylua 2.5.2, lune 0.10.4, rojo, selene 0.27.1.
  `scripts/dev/lune-spec-harness.luau` is the headless runner (pure modules only).

## Ease-of-use pass (2026-10-07, after the restructure)

Asked for after a review of the restructured editor. All in; Studio still has to look at it (nothing headless renders).

- **Readout:** a pinned action bar (name, saved state, Save / Test / Undo / Redo) over a scrolling rest; Revert,
  Duplicate, Delete / Reset are MORE ACTIONS in the scroll.
- **Panel size:** `ScreenFrame.FitToViewport` -> `ModalScreen.FitSize` -> `ViewportScale.Fit`: the viewport curve,
  lowered as far as it takes for 1240x780 to fit (floor 0.6).
- **Hints on demand:** `NumericField`/`Toggle` `HintVisible`; `Fields.Hint`; `context.Hints` (the "Show hints"
  switch) and `context.RegisterHelp` feeding the help strip (pointer, gamepad selection, focused text box).
- **Changed-field dots:** every bound field is wrapped by `Fields.Tracked`; it compares `Get(draft)` with
  `Get(context.Saved)`, and the dot writes the saved value back through the field's own `Set`. The saved move
  comes from the new `MoveEntry.Saved` (sent by `MoveEditorSystem.buildEntry` only while it differs).
- **Timeline:** edge handles retime (throttled commits, Shift = frames); the bar scrubs `ScrubTime`, which
  `Client/DevTools/MoveEditor/ClipScrubber.lua` turns into the local character held at that clip instant.
  ClipScrubber also plays an animation id / sound id once (`PreviewAssetRequested`).
- **Pickers:** `Fields.MovePicker` (Prerequisite, effect Move id, clash override), `Fields.Suggestions`
  (Category), `Fields.Palette` (colours), `Fields.Text` `Action` (Play) and `Extra`.
- **Presentation:** one lazy, summarised `Fields.Section` per moment; `Fields.Fold` is gone (no callers left).
- **Hitbox:** Offset shown Right / Up / Forward (Z flipped in the form and Place mode's bar only); projectile
  SPAWN under BODY; HOMING, COLLISION, PARRY start folded; preset chips describe themselves on hover.
- **Browser / New:** type tags, Clear, `Ctrl+F`, Up/Down (`StepSelection` over the browser's `Order`); New asks
  Melee / Projectile / Domain and lands on Hitbox or Realm.
- **Realm tab:** Realm, Boundary, Effects, Law, Clash are one top-level tab with a sub-tab bar;
  `handle.ShowPage(name)` routes a refusal to either kind of page.
- Verified: selene 0.31.0 0/0 on src/; stylua clean on touched files; `MoveEditorScreen.spec` 17/17 headless
  (new: dots, hints, arrow keys, Realm sub-pages). The harness now models Workspace's camera at the reference
  size, which also lets `ScreenFrameScreens`' Settings case pass. Other headless failures are unchanged from
  the base commit.
