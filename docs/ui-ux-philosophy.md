# UI & UX Philosophy

Visual language and interaction conventions for every player-facing surface: HUD, menus, combat
feedback, inventory, loadout, progression, lobby, and social interfaces.

---

# Aesthetic Direction

## Core Identity

Sleek, sharp Soulslike visual language inspired by modern dark-fantasy action RPGs (primary
reference: Lords of the Fallen, modern interpretation). "A precise combat interface built from
ancient knowledge and advanced craftsmanship."

The UI should feel cold, controlled, powerful, mysterious, tactical, ancient but refined — the
player is accessing a powerful system of the world, not opening a normal game menu.

---

# Visual Style Rules

## Overall Appearance

**Do:** sharp geometric shapes, thin metallic borders, layered transparent panels, subtle
atmospheric glow, high-contrast information hierarchy, clean spacing. Every element intentionally
placed.

**Avoid:** generic Roblox UI styles, rounded modern app design, excessive decoration, bright
fantasy colors, cartoon elements, overly complex ornamentation.

---

# Color Language

## Base Palette

Deep-violet void with bronze as a second accent — cold, dark, restrained, sharp-edged. Panels
should feel like dark glass or forged metal. Source of truth for exact values is `Tokens.Color`
(backgrounds/accents/text) and `Tokens.Border`/`Tokens.Wash` (translucent strokes/fills) — don't
hardcode a color here that can drift from there.

## Primary Colors

### Neutral UI

Used for backgrounds, containers, borders, and secondary information — `Background` /
`Surface` / `SurfaceElevated` (darkest to lightest) plus the three text steps (Primary >
Secondary > Disabled; Disabled must still clear a legibility floor, never fade to invisible).

`AccentPrimary` (violet) reads as interactive/live/selected; `AccentSecondary` (bronze) reads as
committed/permanent/already-spent. Borders and fills are alpha-derived (one hue at varying
opacity), not pre-composited hexes — see `# Borders` below.

---

# Gameplay State Colors

Colors should communicate information instantly.

| Vital | Theme | Visual feeling |
| --- | --- | --- |
| Health | crimson, dark red, blood-like tones | life force, damage, danger |
| Qi / Energy | pale cyan, frost blue, white-blue glow | spiritual energy, internal power, mastery |
| Posture | amber, burnished gold | instability, breaking point, vulnerability |

Kept in their own `Tokens.VitalColor` table, separate from the chrome palette (`Tokens.Color`) —
the chrome's primary accent is called "qi" at the design source (the violet Meridian-fragment),
which would otherwise collide with the Qi *vital* (pale cyan). Separating the tables turns that
mixup into a compile error instead of every button in the game going pale cyan.

### Stamina

Removed from the game entirely — Health/Qi/Posture are the complete set of vitals. Actions are
gated by cooldowns and commitment locks, not a spendable resource. This header is kept as a
pointer for anyone who finds an older reference to it.

### Critical States

Examples: low health, broken posture, ultimate ready.

Use pulsing highlights, increased brightness, controlled animation. Color is never the only
signal — pair it with a shape/motion cue (`Bar`/`VitalIcon`'s `CriticalBelow` prop). Never use
excessive flashing.

---

# Shape Language

## Panels

Two registers, both avoiding perfect rounded rectangles, bubble UI, and soft mobile-style cards:

- **Combat surfaces** (hotbar tiles, `AbilitySlot`, `VitalIcon`) — a true cut-corner (chamfered)
  silhouette, generated at runtime by `ChamferedSurface.lua`, 9-sliced from a 40px tile through a
  300px+ panel. Falls back to sharp-rect + hairline stroke automatically when unavailable
  (`ChamferedSurface.IsAvailable()` — requires the experience owner to be ID-verified with "Allow
  Mesh/Image APIs" enabled in Studio's Security settings, which also blocks Studio Play-mode, not
  just published builds).
- **Menu/panel surfaces** — sharp rectangle, 2px hairline radius, 1px translucent border, square
  corner brackets, and a tiled hex-lattice texture at ~2.5% opacity carrying the hexagonal
  influence instead of the silhouette.

Chamfering a menu panel, or squaring off a hotbar tile, is the wrong register — not a stylistic
choice either way.

---

# Borders

Thin, metallic, slightly glowing, subtle. Borders communicate importance: higher importance gets
a brighter edge highlight and more contrast; lower importance gets reduced opacity.

Expressed as `{Color, Transparency}` pairs (`Tokens.Border`), not pre-composited hexes — Roblox
splits color and transparency across two properties, and the same value reads differently over
`Background` than over `Surface`, so don't flatten them.

---

# Typography

Three families, mapped to Roblox built-ins (no font-upload pipeline exists yet, so swapping in
real assets later is a one-line change per family in `Tokens.lua`): a display serif for headers
and proper nouns, a squared sans for instructional text, a mono for every numeral. Set through
`FontFace` (a real `Font` datatype with weight + italic), not `Enum.Font` — the type scale needs
weights `Enum.Font` can't express. Roblox has no letter-spacing property; tracked all-caps labels
are built per-character by `Components/TrackedLabel.lua`, for short static strings only.

## Headers

Character names, menu titles, major information. Strong, wide spacing, sharp.

## Body Text

Descriptions, stats, details. Highly readable, neutral, clean.

## Combat Text

Prioritize, in order: visibility, speed of recognition, contrast. Combat text should never
require reading effort.

---

# HUD Design

The HUD should feel like part of combat, not an overlay. Minimal, informative, out of the
player's way. Every element exists because it provides gameplay value.

---

# Player Status Display

Health / Qi / Posture / Level / active effects, as compact segmented bars that feel alive rather
than simply fill: a subtle pulse on damage, an energy-flow glow on Qi gain, increasing
instability as posture drops. Level renders via `TierBadge` — the server owns tier identity (its
never-demote rule makes that genuinely underivable from XP alone), the client only computes the
fill fraction locally against the replicated XP window (`Types.TierUpdatePayload`).

---

# Ability System UI

Ability UI should communicate power and cooldown state instantly. Each slot carries: icon,
keybind, cooldown timer, resource requirement, state indicator.

| State | Appearance |
| --- | --- |
| Available | clear icon, strong contrast, slight energy glow |
| Cooldown | darkened icon, radial/vertical cooldown wipe, remaining-time readout |
| Locked | desaturated, disabled, minimal attention |
| Active | bright edge highlight, energy animation, temporary emphasis |

---

# Combat Feedback

The most important part of the UI — it must communicate information instantly during high-speed
fights. The sections below (through Notification Design) describe target design intent for
surfaces that mostly don't exist yet — build against real data from the owning server System when
it exists, don't fabricate content ahead of it (see `# Current Build Status`).

---

# Damage Numbers

Large enough to instantly recognize, short-lived, high contrast, directionally readable.
Different damage types need different visual identities: normal (clean white), heavy (larger,
stronger impact), critical (larger emphasis, unique animation), posture (separate visual
language).

---

# Hit Feedback

Successful attacks provide small visual confirmation and impact emphasis. Avoid excessive screen
effects or anything that covers gameplay.

---

# Posture Break Feedback

A major gameplay moment: strong visual indicator, clear enemy vulnerability state, high-impact
animation. The player should immediately understand "the enemy is exposed."

---

# Lock-On UI

Precise and tactical: minimal reticle, clear target identification, smooth movement, strong
visibility. Avoid large distracting circles or blocking enemy animations.

---

# Notification Design

Notifications feel like world events (item acquired, quest completion, rank change, progression
milestone): controlled entrance animation, sharp panels, minimal text, clear hierarchy.

---

# Menu Design

Menus can be more detailed than the combat HUD and should feel like accessing deeper systems —
larger panels, more visual effects, background animations, lore elements — while still using the
same palette, geometry, and typography as everything else.

---

# Inventory / Equipment

Emphasize item rarity, build decisions, character identity: clean item cards, weapon silhouettes,
stat comparison, equipment highlights. Avoid cluttered MMO inventory grids.

---

# Progression Screens

Bloodlines, Skills, Art trees, Factions. Should feel ancient, important, connected to the world:
network patterns, energy connections, unlock animations, progress visualization.

---

# Lobby / Loadout UI

Establishes player identity before entering gameplay: character presentation, equipment, build
choices, ready state. The player should feel prepared before combat begins.

---

# Animation Philosophy

Smooth, controlled, intentional — never bouncy, arcade-like, or rushed. Preferred motion: fade,
slide, energy buildup, mechanical unfolding.

Two mechanisms, picked by what's moving, not by taste: a spring for a continuously-changing live
value (health draining, a reticle chasing a target — settle time is emergent), a tween for a
discrete state transition with a designed duration (a card being selected, a screen entering).
Presets live in `Tokens.Motion`.

---

# Final Design Rule

Every UI element must answer: "does this make the player feel more connected to the world and
combat?" If not, remove it.

---

# Framework

Built in Fusion (`elttob/fusion@0.3.0`, scoped API — `Fusion.scoped`, `scope:New`,
`scope:Value`, `scope:Computed`, `scope:Spring`, `Fusion.Children`, `Fusion.OnEvent`; not the
older global `New`/`Value` style), chosen for how well its reactive model fits fast-changing
combat feedback. Lives entirely under `StarterPlayer/StarterPlayerScripts/Client/UI/`.

```
UI/
  init.lua               -- UI.Mount(), the single entry point (called once from Main.client.lua)
  Tokens.lua              -- design tokens: colors, spacing, corner radius, type scale, motion
  Geometry.lua            -- shared row/column layout math
  Meter.lua               -- shared fill/gauge math for VitalIcon and Bar
  ChamferedSurface.lua    -- runtime-generated cut-corner tile/panel silhouette
  State/
    ClientState.lua       -- Fusion Values reflecting server-validated state
  Components/             -- reusable primitives, one file each
  Screens/                -- one folder per Surface (HUD, Menus, DevTools, Onboarding,
                           -- DeathFeed, CombatFeedback, BugReport, Announcement, ...)
```

Rules:
- A component is `ComponentName(scope, props) -> Instance`, PascalCase, and never opens its own
  root `Fusion.scoped` — it receives one from its caller, all the way up to `UI/init.lua`'s single
  call. (Two documented exceptions, both explained in their own module's header: `Onboarding`'s
  temporary scope, and `UI/init.lua`'s Studio hot-reload teardown path.)
- Colors, spacing, and type come from `Tokens.lua` exclusively — no hardcoded
  `Color3.fromRGB(...)` inside a component.
- `ClientState.lua` is the only place allowed to hold Fusion Values representing
  server-validated game state, written exclusively by a `NetworkBridge` remote handler inside
  `ClientState.Bootstrap()`. A field may be added ahead of its owning server System existing
  (full-bar/render-only default) but is only wired to real data once that System actually fires
  the corresponding remote.
- Combat HUD elements must update in the same frame as server-validated state — no optimistic
  HUD state that can visibly desync from actual outcomes. This governs which *values* drive a
  visual (always the real, un-smoothed fraction for anything gameplay-decision-relevant, like a
  critical threshold crossing); purely decorative interpolation (a `scope:Spring`-smoothed fill so
  a bar doesn't snap instantly) is fine — it changes presentation, not information.
- **`Mount()` return-value contract:** an always-on, non-interactive Screen (`HUD`, `DeathFeed`)
  returns the bare `ScreenGui` — it has no open/closed state to expose. A toggleable/interactive
  Screen (`Menus`, `DevMenu`, `BugReport`, `CombatFeedback`) returns a `*Handle` table exposing
  whatever open/closed state and signals its owning `*Client.lua` module needs. Pick whichever
  shape matches whether the Screen has real open/closed state to expose.

---

# Current Build Status

**Built:**
- **HUD hotbar dock** (`Screens/HUD/init.lua`, rebuilt 2026-08-25) — four stacked bands: an
  engagement readout (`HUD/EngagementLine.lua`, off `ClientState.InCombat`), the bounty pill, the
  dock itself, and a key legend (`Components/KeyLegend.lua`, spelled live from `KeybindManager`).
  The dock holds three modules — `TierBadge` (a bronze numeral plate beside its name/meter/percent),
  Health/Qi/Posture as 48px `VitalIcon` gauges, and a 5-slot `AbilitySlot` row at 56px — with the
  vitals and slots in recessed group wells and a faded vertical hairline as each seam. The panel is
  chamfered *and* bracketed: `Panel`'s `BracketInset` sets each bronze elbow to
  `ChamferedSurface.CHAMFER_PX` so the arms brace the cut instead of floating over it.
- **Armament island** (`Screens/HUD/ArmamentIsland.lua`, 2026-08-25) — the weapon readout, **bolted
  to the dock's left edge** rather than parked near it, and the reference for how two surfaces are
  joined in this UI. Four rules make a butt joint read as one object instead of two panels touching:
  the gap is *zero* (same coordinate, not a small distance); the island draws **no edge on the shared
  side** (its plate is built wider than its clipping slot, so its own stroke, right chamfer cuts and
  right brackets are cut off at the seam and the dock's left rule is the only rule there); both
  plates are the **same height**, so their top and bottom edges are continuous; and bronze brackets
  appear only at the *assembly's* four outer corners, never at the interior seam. One bronze bead
  straddles the joint as its visible fastener. Attaching anything else to a surface should copy that
  list — a shared seam is the one place where "the same material family" is not enough, because any
  difference in edge, silhouette or bracket lands within a pixel of its counterpart. The island is
  **pinned, not laid out** (see that file's header), which is what makes the dock's position provably
  immovable while an under-damped spring changes the island's width.
- **The dock's "alive" cues cost nothing at rest**, and that is the pattern to copy rather than a
  detail of these two files. `VitalIcon`'s damage flare and gain bloom are the signed lag between the
  real fraction and its own spring (`smoothed - real` is positive only while falling); `AbilitySlot`'s
  ready flash is the state spring it already had, travelling its full range on a Cooldown → Available
  edge. Neither needs a timer, a flag, or the caller to announce the event, and both are exactly 0
  when nothing is happening — so no Computed downstream of them re-evaluates on an idle frame.
- **Combat-state badge** — removed with the rest of the old combat system. Nothing publishes an
  in-combat edge in the rebuilt stack (`ClientState.InCombat` exists and stays false), so the
  engagement readout above the dock reports the state it is given rather than fabricating one.
- **Admin panel** (`Screens/DevTools/DevMenu/*`, rebuilt 2026-09-29) — the live-server control tool,
  on the Move Editor's shape: `ScreenFrame` tabs (`Player`/`World`/`Server`/`Reports`/`Tuning`)
  between two pinned rails — a live roster on the left whose selection is the TARGET of the Player
  tab, and an inspector on the right showing that player's server-side state (vitals, combat,
  cultivation, overrides). No cards; built from shared components through a small local `Kit.lua`.
  Irreversible actions use `Components/ArmedButton`. See `docs/design/admin-panel-guide.md`.
- **Move Editor** (`Screens/DevTools/MoveEditor/*`, rebuilt 2026-09-29) — the admin-only authoring
  tool for combat moves, and the reference for how a dense TOOL wears this frame: `ScreenFrame` tabs
  (`Hitbox`/`Timing`/`Impact`/`Identity`) between two pinned rails — a grouped move browser on the
  left, and a readout on the right holding the RESULTS of the inputs (hitbox plots, the effective
  timeline, notes, actions). No cards: groups are bronze `SectionHeading`s and spacing. Built only from
  shared components and `Tokens` — no screen-scoped palette. Its hitbox plots rasterise the engine's
  own `ContainsPoint` rather than drawing a shape, so the preview cannot disagree with the hit. A fifth
  tab, `Tools` (2026-09-29), holds what acts on more than one move's inputs -- bulk edit, version
  history, and the Studio-only SOURCE section -- and the readout grew FRAME DATA, the TEST BENCH and a
  HIT LOG as components of their own. **Place mode** is the one surface that leaves the frame: the modal
  steps aside (the session stays open) and a small unscaled `Shell/Surface` bar in the Overlay band
  (`PlacementBar.lua`) carries the tool/snap segments, a live offset readout, Done and a `KeyLegend`,
  while Roblox `Handles`/`ArcHandles` on the in-world volume do the dragging. See
  `docs/design/move-editor-guide.md`.
- **Onboarding** (`Screens/Onboarding/*`) — a skippable intro cinematic followed by a mandatory
  4-screen character creator, gated purely on `profile.raceId == nil`. Runs its own temporary
  Fusion scope, cleaned up before `UI.Mount()` is called.
- **Source icon/frame art**: `docs/design/icons/*.svg` (one hand-authored vital icon each, not
  yet uploaded — `VitalIcon`'s `IconAssetId` prop is the wiring point) and
  `docs/design/frames/hotbar-frame.svg` (already live via `Panel.lua`'s `CornerAccent` prop —
  Frame/UIStroke composition, no asset needed).

**Not built** (blocked on the owning server System producing real data): ability slot content,
damage numbers, hit feedback, lock-on UI, notifications, Menu/Inventory/Progression/Lobby
screens.
