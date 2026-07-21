# UI & UX Philosophy

Visual language and interaction conventions for every player-facing surface:
HUD, menus, combat feedback, inventory, loadout, progression, lobby, and social interfaces.

This document defines the complete visual identity of Shattered Meridian's UI.
Every interface must feel like it belongs to the same world.

This is the project's canonical UI/UX design doc, checked into the repo so it persists and
travels with the code (a prior, thinner version of this doc lived only in an external tool's
session cache and didn't survive between sessions -- see "Implementation Notes" at the bottom for
what that means for anyone picking this up later).

---

# Aesthetic Direction

## Core Identity

The UI follows a sleek, sharp Soulslike visual language inspired by modern dark fantasy action RPGs.

Primary reference:
- Lords of the Fallen (modern interpretation)

The intended aesthetic:

"A precise combat interface built from ancient knowledge and advanced craftsmanship."

The UI should feel:
- Cold
- Controlled
- Powerful
- Mysterious
- Tactical
- Ancient but refined

The player should feel like they are accessing a powerful system of the world rather than opening a normal game menu.

---

# Visual Style Rules

## Overall Appearance

UI should have:

- Sharp geometric shapes
- Thin metallic borders
- Layered transparent panels
- Subtle atmospheric glow
- High contrast information hierarchy
- Clean spacing
- Minimal visual noise

Every element should appear intentionally placed.

Avoid:

- Generic Roblox UI styles
- Rounded modern app designs
- Excessive decoration
- Bright fantasy colors
- Cartoon-like elements
- Overly complex fantasy ornamentation

---

# Color Language

## Base Palette

The entire UI uses a cold blue-grey foundation.

Background surfaces:

- Deep charcoal
- Blackened steel
- Dark blue-grey
- Frosted transparent layers

Panels should feel like dark glass or forged metal.

---

## Primary Colors

### Neutral UI

Used for:

- Backgrounds
- Containers
- Borders
- Secondary information

Colors:
- Dark slate
- Steel grey
- Muted blue-grey
- Off-white text

---

## Gameplay State Colors

Colors should communicate information instantly.

### Health

Theme:
- Crimson
- Dark red
- Blood-like tones

Visual feeling:
Life force, damage, danger.

---

### Qi / Energy

Theme:
- Pale cyan
- Frost blue
- White-blue glow

Visual feeling:
Spiritual energy, internal power, mastery.

---

### Stamina

Theme:
- Muted green
- Natural energy tones

Visual feeling:
Physical endurance.

---

### Posture

Theme:
- Amber
- Burnished gold

Visual feeling:
Instability, breaking point, vulnerability.

---

### Critical States

Examples:
- Low health
- Broken posture
- Ultimate ready

Use:
- Pulsing highlights
- Increased brightness
- Controlled animation

Never use excessive flashing.

---

# Shape Language

## Panels

Panels should use:

- Angular corners
- Asymmetric cuts
- Thin outlines
- Layered depth

Examples:

Preferred:
- Hexagonal influences
- Slanted corners
- Weapon-like geometry
- Forged metal appearance

Avoid:
- Perfect rounded rectangles
- Bubble UI
- Soft mobile-style cards

---

# Borders

Borders should be:

- Thin
- Metallic
- Slightly glowing
- Subtle

Borders communicate importance.

Higher importance:
- Brighter edge highlight
- More contrast

Lower importance:
- Reduced opacity

---

# Typography

Typography should communicate hierarchy.

## Headers

Used for:

- Character names
- Menu titles
- Major information

Style:
- Strong
- Wide spacing
- Sharp appearance

---

## Body Text

Used for:

- Descriptions
- Stats
- Details

Style:
- Highly readable
- Neutral
- Clean

---

## Combat Text

Prioritize:

1. Visibility
2. Speed of recognition
3. Contrast

Combat text should never require reading effort.

---

# HUD Design

The HUD should feel like part of combat, not an overlay.

It should remain:

- Minimal
- Informative
- Out of the player's way

Every element exists because it provides gameplay value.

---

# Player Status Display

The player status area should contain:

- Health
- Qi
- Stamina
- Posture
- Level
- Character information
- Active effects

Design:

- Compact horizontal or stacked bars
- Sharp segmented structure
- Subtle animations
- Reactive energy effects

Bars should not simply fill.

They should feel alive.

Examples:

Health:
- Subtle pulse when damaged
- Smooth loss animation

Qi:
- Energy flow effect
- Soft glow increase

Posture:
- Increasing instability effects

---

# Ability System UI

Ability UI should communicate power and cooldown state instantly.

Each ability slot should contain:

- Ability icon
- Keybind
- Cooldown timer
- Resource requirement
- State indicator

States:

## Available

Appearance:
- Clear icon
- Strong contrast
- Slight energy glow

---

## Cooldown

Appearance:

- Darkened icon
- Circular or vertical cooldown animation
- Remaining time indicator

---

## Locked

Appearance:

- Desaturated
- Disabled appearance
- Minimal attention

---

## Active

Appearance:

- Bright edge highlight
- Energy animation
- Temporary emphasis

---

# Combat Feedback

Combat feedback is one of the most important parts of the UI.

It must communicate information instantly during high-speed fights.

---

# Damage Numbers

Damage numbers should be:

- Large enough to instantly recognize
- Short-lived
- High contrast
- Directionally readable

Different damage types require different visual identities.

Normal damage:
- Clean white numbers

Heavy damage:
- Larger size
- Stronger impact

Critical damage:
- Larger emphasis
- Unique animation

Posture damage:
- Separate visual language

---

# Hit Feedback

Successful attacks should provide:

- Small visual confirmation
- Impact emphasis
- Clear response

Avoid:
- Excessive screen effects
- Covering gameplay

---

# Posture Break Feedback

Posture breaks are major gameplay moments.

Feedback should include:

- Strong visual indicator
- Clear enemy vulnerability state
- High-impact animation

The player should immediately understand:

"The enemy is exposed."

---

# Lock-On UI

Lock-on should feel precise and tactical.

Design:

- Minimal reticle
- Clear target identification
- Smooth movement
- Strong visibility

Avoid:

- Large distracting circles
- Blocking enemy animations

---

# Notification Design

Notifications should feel like world events.

Examples:

- Item acquired
- Quest completion
- Rank changes
- Progression milestones

Style:

- Controlled entrance animation
- Sharp panels
- Minimal text
- Clear hierarchy

---

# Menu Design

Menus can be more detailed than combat HUD.

They should feel like accessing deeper systems.

Allowed:

- Larger panels
- More visual effects
- Background animations
- Lore elements

Still maintain:

- Same palette
- Same geometry
- Same typography

---

# Inventory / Equipment

Design should emphasize:

- Item rarity
- Build decisions
- Character identity

Use:

- Clean item cards
- Weapon silhouettes
- Stat comparison
- Equipment highlights

Avoid:

- Cluttered MMO inventory grids

---

# Progression Screens

Examples:

- Bloodlines
- Skills
- Art trees
- Factions

Should feel:

- Ancient
- Important
- Connected to the world

Use:

- Network patterns
- Energy connections
- Unlock animations
- Progress visualization

---

# Lobby / Loadout UI

Should establish player identity before entering gameplay.

Focus on:

- Character presentation
- Equipment
- Build choices
- Ready state

The player should feel prepared before combat begins.

---

# Animation Philosophy

Animations should be:

- Smooth
- Controlled
- Intentional

Avoid:

- Excessive bouncing
- Arcade-like effects
- Overly fast transitions

Preferred motion:

- Fade
- Slide
- Energy buildup
- Mechanical unfolding

---

# Final Design Rule

Every UI element must answer:

"Does this make the player feel more connected to the world and combat?"

If not, remove it.

The UI should feel like an extension of Shattered Meridian itself:
cold, powerful, ancient, and precise.

---

# Implementation Notes (Shattered Meridian codebase)

Everything above this line is the design canon, verbatim as authored. Everything below is
engineering context for whoever (human or Claude) implements against it next.

## Stamina was removed (supersedes the canon Stamina sections above)

Stamina has been **removed from the game entirely.** This note supersedes the two Stamina
references in the design-canon block above (the "### Stamina" theme entry under Gameplay State
Colors, and the "Stamina" line in the Player Status Display list) -- those are preserved verbatim
as the original authored record, but they no longer describe the shipped game. An earlier pass had
reconciled Stamina against combat-philosophy.md's "not a stamina-drain turtle simulator" line; that
reconciliation is moot now that the resource is gone.

Why it was removed:

- **The Sekiro-grade reference point in combat-philosophy.md has no stamina** -- it's health +
  posture. Stamina was never in that doc's "Established systems" list. Removing it makes the game
  more faithful to its own north star, not less.
- **Posture is now the sole meaningful non-health resource** -- exactly the "turns sustained
  aggression into an opening" mechanic the reference always centered.
- **Actions are gated by cooldowns + the attackEndsAt commitment lock (+ posture), not a stamina
  budget.** Attacks, parry, and dash each have their own cooldown/commitment; nothing is
  stamina-limited anymore.

Code impact (already applied):

- `Types.CombatVitalsPayload`/`CombatSnapshot` and `Constants.Combat` no longer carry any
  Stamina/MaxStamina/StaminaCost/StaminaRegen field.
- The central hotbar (`Screens/HUD/init.lua`) is now **Health / Qi / Posture** -- the Stamina
  `VitalIcon` and its `Tokens.Color.Stamina` token are gone (the `Ring` glyph primitive it used
  remains available in `VitalIcon.lua`, just unassigned).
- The neutral-game movement added alongside this change (**Sprint** + **Dash**, in
  `CombatSystem.lua`) costs no resource: Sprint is gated by combat state, Dash by its own cooldown.

If combat design ever wants a spendable action-economy resource again, that's a fresh combat-design
decision to make deliberately -- not a reinstatement this UI doc should be read as implying.

## Framework

Built in Fusion (Roblox's reactive state library), chosen for how well its reactive state model
fits fast-changing combat feedback (health/posture/qi, damage numbers, lock-on reticles).

The UI framework lives entirely under `StarterPlayer/StarterPlayerScripts/Client/UI/`. Fusion is
pinned at `elttob/fusion@0.3.0` (`wally.toml`) and uses its scoped API (`Fusion.scoped`,
`scope:New`, `scope:Value`, `scope:Computed`, `scope:Spring`, `Fusion.Children`, `Fusion.OnEvent`
-- not the older global `New`/`Value` style from Fusion 0.1/0.2).

```
UI/
  init.lua               -- UI.Mount() -- the single entry point, called once from Main.client.lua
  Tokens.lua              -- design tokens: colors, spacing, corner radius, type scale
  State/
    ClientState.lua       -- Fusion Value objects reflecting server-validated state
  Components/
    Panel.lua Label.lua Button.lua Bar.lua VitalIcon.lua AbilitySlot.lua  -- reusable primitives
  Screens/
    HUD/ Menus/ DeathFeed/    -- the three Surfaces, one folder each
```

- Every component is a function `ComponentName(scope, props) -> Instance`, PascalCase. Components
  never create their own root scope -- they receive one from their caller, all the way up to
  `UI/init.lua`'s single `Fusion.scoped(Fusion)` call.
- Props accept `Fusion.UsedAs<T>` wherever a real app might want to drive that prop reactively.
- A component pulls color/spacing/type values from `Tokens.lua` exclusively -- no hardcoded
  `Color3.fromRGB(...)` inside a component.
- `ClientState.lua` is the only place allowed to hold Fusion Values that represent
  server-validated game state. Every field is written to exclusively by a `NetworkBridge` remote
  handler inside `ClientState.Bootstrap()`. A field gets added to `ClientState` (with a
  full-bar/render-only default) before its owning server System exists, exactly the way
  Health/Posture were added ahead of `CombatSystem` -- that's an established, sanctioned pattern
  in this codebase, not an exception. The field is only *wired to real data* (a Bootstrap listener
  added) once the owning System actually fires the corresponding remote.
- Combat HUD elements must update in the same frame as server-validated state -- no optimistic HUD
  state that can visibly desync from actual outcomes. This governs which *values* drive a visual
  (always the real, un-smoothed fraction for anything gameplay-decision-relevant, like a critical
  threshold crossing); purely decorative interpolation (e.g. a `scope:Spring`-smoothed fill
  animation so a bar doesn't snap instantly) is fine even though it lags a few frames, because it
  doesn't change what information the player is being given, only how it's presented.

## Current build status

- **Built:** the central hotbar (`Screens/HUD/init.lua`) -- Health/Qi/Posture as 52px
  icon-tile gauges (`Components/VitalIcon.lua`) with a forged-metal gradient sheen, a faint
  battle-wear scratch accent, and a `scope:Spring`-smoothed fill, stacked over a 40px, 5-slot
  ability row (`Components/AbilitySlot.lua`). Every ability slot renders the doc's "Locked"
  appearance (desaturated, minimal attention) with only a keybind number -- see AbilitySlot.lua's
  header for why that's the mount point, not fabricated ability content.
- **Built: combat-state badge** (`Components/CombatStateBadge.lua`) -- a compact pill above the
  hotbar that mechanically unfolds into view (height-driven, not a `Visible` toggle) the instant
  `CombatState.inCombatUntil` goes live server-side, and folds back away the instant it lapses.
  This is a new visual pattern (documented here per this file's own "Extending this file" rule):
  a genuinely optional, event-driven HUD element whose *presence* is the primary signal rather
  than a color change on an always-shown element, reserved for state that is meaningfully absent
  most of the time (unlike Health/Posture, which are always relevant). Backed by a from-scratch
  blade glyph (distinct from VitalIcon's Cross/Spark/Diamond/Ring set) so the badge is never
  mistaken for a fifth vital. `inCombatUntil` had been computed server-side with no consumer at
  all before this -- this badge is its first one, wired over a new fire-on-transition remote
  (`Combat_InCombatChanged`, same shape as `Combat_ComboStateChanged`). Purely presentational: no
  request handler gates on this flag, so nothing about combat legality changed to add it.
- **Real source icon art exists, but isn't live in-game yet:** `docs/design/icons/*.svg` -- one
  genuine hand-authored icon per vital (notched dagger / fractured shard / tattered pennant /
  cracked shield), gritty and battle-torn per the Aesthetic direction. Roblox has no SVG support
  at runtime -- `ImageLabel.Image` only accepts a `rbxassetid://` pointing at an uploaded raster
  texture, and this repo has no asset-upload pipeline (nor should one guess an asset id; that
  renders as a broken image, not a placeholder). `VitalIcon.lua` takes an optional `IconAssetId`
  prop specifically so wiring a real id in later is a one-line change per vital, not a rewrite --
  until then it falls back to the procedural glyph (Frame/UIStroke geometry, no asset needed).
- **Corner-bracket frame, live in-game (no asset needed):** `docs/design/frames/hotbar-frame.svg`
  is the source art for the hotbar's outline -- four tactical, forged-steel corner brackets with a
  rivet chip at each elbow. Unlike the vital icons, this one *is* already rendering exactly as
  drawn: `Components/Panel.lua`'s `CornerAccent` prop (opt-in, off by default for other panels)
  ports the same bracket geometry to Frame/UIStroke composition, so it never needed an image asset
  in the first place. This is an additive overlay on the existing sharp-rectangle panel, not a
  true cut-corner silhouette -- see the Shape Language gap noted below for what a real angular
  panel *shape* would still require.
- **Not built yet, and why:** Ability System UI *content* (needs `CombatSystem`/`ArtSystem` to
  exist and fire real icon/cooldown/resource state -- the slot shell above is real, what goes in
  each slot isn't), damage numbers and hit feedback (needs `CombatSystem`), lock-on UI (needs
  `CombatSystem`), notifications (needs the relevant systems -- reward, progression, faction -- to
  fire real events), Menu/Inventory/Progression/Lobby screens (need `PlayerDataSystem`,
  `BloodlineManager`, `ArtTreeManager`, `FactionManager` to hold real data). Building any of these
  now would mean fabricating data no server System produces yet -- see this doc's Framework
  section above on server-owns-truth. Level and "character information" in the Player Status
  Display are the same story: `TierSystem`/`PlayerDataSystem` are still empty `Init()`s, so
  there's no real tier/name to show yet.
- **Shape language not yet implemented:** true angular/hexagonal/slanted-corner panels (as opposed
  to the current sharp-but-rectangular `UICorner` treatment) need either custom 2D polygon
  geometry (`EditableMesh`/`EditableImage`) or commissioned corner-cut image assets -- neither
  exists in this repo yet. Current panels use `Tokens.CornerRadius = UDim.new(0, 0)` (fully sharp
  rectangles) as the closest achievable approximation without that asset/geometry work. Treat this
  as a known gap, not a design deviation.
