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

## The base palette is now violet/bronze (supersedes the canon Color Language + Borders sections)

The "cold blue-grey foundation" described in the Base Palette / Primary Colors sections above is
**no longer the shipped palette.** Those sections are preserved verbatim as the original authored
record, but the game's chrome is now a deep-violet void with bronze as its second accent. Source of
truth for the change is a Figma redesign of the character-creation flow, applied game-wide.

| Role | Was (cold blue-grey) | Now (violet/bronze) |
| --- | --- | --- |
| Background | `13, 17, 23` | `8, 6, 16` |
| Surface | `21, 27, 36` | `13, 10, 22` |
| SurfaceElevated | `30, 38, 51` | `19, 16, 32` |
| Primary accent | `79, 168, 216` (`BorderAccent`) | `154, 136, 200` (`AccentPrimary`) |
| Secondary accent | *(none existed)* | `196, 164, 110` (`AccentSecondary`, bronze) |
| TextPrimary | `232, 236, 239` | `200, 192, 216` |

Why the change was accepted despite this doc's own "locked visual identity" language: the
replacement is the same *register* -- cold, dark, restrained, sharp-edged, thin-outlined -- moved
one hue family over. Nothing above about ornamentation, shape, or restraint is relaxed by it. What
it buys is a second accent. The old palette had exactly one accent (`BorderAccent`) doing four
unrelated jobs (borders, fills, meter fills, emphasis text); violet + bronze splits "this is
interactive/live" from "this is committed/permanent," which is a distinction the character creator
needs and the rest of the UI will want.

Two structural consequences worth stating, because both are places the old palette was quietly
lying:

- **Vital colors moved out of `Tokens.Color` into `Tokens.VitalColor`.** The redesign's primary
  accent is named "qi" in its source (it's the Meridian-fragment violet), which collided head-on
  with `Tokens.Color.Qi` -- the *gameplay vital*, pale cyan. Two unrelated concepts on one word.
  Health/Qi/Posture now live in their own table, so the collision is a compile error rather than a
  screen full of pale-cyan buttons. **The vitals keep their canon hues** (crimson / pale cyan /
  amber, per the Gameplay State Colors section above, which is NOT superseded) -- distinctness
  between the three vitals outranks hue-cohesion with the chrome.
- **Borders and washes are now alpha-derived.** The design expresses its entire border system as
  one violet at 9% / 18% / 32% opacity, and its fills as white at 1.6%-6%. Roblox splits color and
  transparency across two properties, so these ship as `Tokens.Border` / `Tokens.Wash` tables of
  `{Color, Transparency}` pairs rather than as pre-composited opaque hexes. Do not flatten them --
  the translucency is real and reads differently over `Background` than over `Surface`.

### Shape language: two registers, not one (supersedes "Panels" above)

The canon Shape Language section says to avoid perfect rounded rectangles and prefer slanted
corners and hexagonal influences. That still holds for **combat surfaces** -- the hotbar tiles,
`VitalIcon`, `AbilitySlot`, anything that opts into `ChamferedSurface`. It does **not** describe the
menu/panel register, which the redesign settles as: **sharp rectangle, 2px hairline radius, 1px
translucent border, square corner brackets, and a tiled hex lattice at ~2.5% opacity as the
surface's texture.** The hexagonal influence the canon asks for is carried by that lattice rather
than by the panel silhouette.

Stated explicitly because the two registers look like a contradiction otherwise: an implementer who
chamfers the character-creator panel is following the canon and producing the wrong thing. Chamfer
is for tiles you fight with; brackets-on-a-sharp-rect is for panels you read.

### Typography moved to FontFace

`Tokens.Type` now carries a `Font` datatype (`TextLabel.FontFace`) rather than an `Enum.Font`, so
the type scale can express real weights (300-700) and italic. The three families the design calls
for have no Roblox equivalent and are mapped to built-ins: Cinzel -> `Merriweather` (display
serif), Rajdhani -> `TitilliumWeb` (squared sans), JetBrains Mono -> `RobotoMono` (all numerals).
The mapping lives in one place so swapping in real uploaded fonts later is a single edit.

Roblox has no `letter-spacing` property and no RichText equivalent, so the design's tracked
all-caps labels are built per-character by `Components/TrackedLabel.lua`. That component is for
short static caps strings only -- see its own header for why its `Text` is a plain string rather
than a reactive one.

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
  Geometry.lua            -- shared layout math (row/column sizing helpers)
  Meter.lua               -- shared fill/gauge math VitalIcon and Bar both build on
  ChamferedSurface.lua    -- runtime-generated (EditableImage) true cut-corner tile/panel silhouette,
                           -- shared by Panel/AbilitySlot/VitalIcon's opt-in Chamfered treatment --
                           -- see that module's own header for the technique and its deployment gate
  State/
    ClientState.lua       -- Fusion Value objects reflecting server-validated state
  Components/             -- reusable primitives, one file each (Panel/Label/Button/Bar/VitalIcon/
                           -- AbilitySlot/TextField/CombatStateBadge/... -- see Components/ for the
                           -- full, growing list; this doc doesn't hand-enumerate every file)
  Screens/
    HUD/ Menus/ DeathFeed/ CombatFeedback/ DevMenu/ BugReport/ Announcement/  -- one folder per
                           -- Surface; DevMenu/ further splits into sibling init/Sidebar/
                           -- ContentArea/Types modules -- see "Current build status" below for why
```

**`Mount()` return-value contract.** Every Screen exports a `Mount(scope, playerGui, ...) ->` entry
point, but the return type intentionally splits into two shapes, not one:

- **Always-on, non-interactive surfaces** (`HUD`, `DeathFeed`) return the bare `ScreenGui` they
  built. They have no open/closed state to expose -- the surface is visible for the whole session,
  driven purely by `ClientState`/server feedback -- so a `*Handle` table with a fabricated `IsOpen`
  would be exactly the kind of fabricated-state-that-doesn't-exist this doc's HUD-sync rule (above)
  already forbids elsewhere. `UI/init.lua` discards both return values today; a future caller that
  needs to reach into one of these (e.g. Studio hot-reload teardown) still can, since the instance is
  right there in the return.
- **Toggleable/interactive surfaces** (`Menus`, `DevMenu`, `BugReport`, `CombatFeedback`) return a
  `*Handle` table (e.g. `MenusHandle = { IsOpen: Fusion.Value<boolean> }`) exposing whatever open/
  closed state and `BindableEvent` signals the owning `*Client.lua` module needs to drive it.

A new Screen picks whichever shape matches whether it has real open/closed state to expose --
don't force a Handle onto an always-on Screen just for uniformity, and don't return a bare
`ScreenGui` from a Screen a `*Client.lua` module needs to toggle or listen to.

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
- **Built: true cut-corner tile/panel shape** (`Client/UI/ChamferedSurface.lua`, 2026-07-23) --
  closes the "Shape language not yet implemented" gap this section used to document below. The
  Hotbar panel (`CornerAccent`'s successor, `Panel.lua`'s `Chamfered` prop), every `AbilitySlot`
  tile, and every `VitalIcon` tile (including its own fill gauge, so the gauge's corners never
  square off against the tile's chamfer at high fill levels) now render a real 45-degree
  corner-cut silhouette generated once at runtime via `EditableImage`, 9-sliced so the one baked
  texture stretches cleanly from a 40px tile to the 300px+ Hotbar panel. Every consumer falls back
  to the prior sharp-rect `UICorner`+`UIStroke` treatment automatically if the textures aren't
  available in a given environment (`ChamferedSurface.IsAvailable()`) -- see that module's header
  for the technique and its one real deployment gate (the experience owner must be ID-verified and
  enable "Allow Mesh/Image APIs" in Studio's Game Settings > Security -- CONFIRMED 2026-07-23 via a
  live Output log that this also blocks Studio Play-mode testing, not just a published build; an
  earlier draft of this note wrongly claimed Studio was unaffected). `AbilitySlot.lua` also gained a restrained
  always-on "empty slot" reticle + corner-tick accent (`Components/CornerBracket.lua`, extracted
  from `Panel.lua`'s own corner-bracket geometry and parameterized so each caller picks its own
  scale) -- neither depends on `ChamferedSurface`, so both still render even when the chamfered
  textures fall back.
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
- **Built: DevMenu Sidebar/Admin-panel shell** (`Screens/DevMenu/{init,Sidebar,ContentArea,Types}.lua`)
  -- the dev menu's original single ~1545-line file split into a thin root (`init.lua`: ScreenGui >
  Root Panel > Header/Body/Footer, owns `IsOpen`/`StatusText` and the root's top-level layout budget)
  plus two sibling Screens: `Sidebar.lua` (a PERSISTENT left column -- Player-Count/Bug-Reports-Open/
  Suspected-Cheater stats header + the player roster, visible regardless of which tab is selected) and
  `ContentArea.lua` (the tabbed right column -- Spawn/Admin/Tuning/Reports; "Players" was dropped as a
  tab once the roster moved into Sidebar permanently). `Types.lua` holds every type both Screens share
  so neither requires the other. Each column receives only a `(width, bodyHeight)` pair from the root
  and owns its OWN internal row-height budget below that (Sidebar's stats-header-vs-roster-scroll
  split, ContentArea's tab-strip-vs-scroll-area split) -- the same "spell out the math, never guess"
  discipline this file's root panel has followed since the original single-file version.
- **Built: `Components/ActionIcon.lua`** -- a compact icon-tile action button (Kick/Ban/Mute/
  Flag-Suspected-Cheater/overflow "⋯" glyphs, all procedural Frame/UIStroke composition matching
  `VitalIcon.lua`'s exact technique, no SVG/asset upload) replacing the roster row's old text buttons.
  Generalizes `Tab.lua`'s persistent `Selected` concept to an icon, plus a SECOND, distinct `Armed`
  state (Ban's two-press confirm window -- a bright/thick border stands in for the old
  "Ban" -> "Confirm Ban?" text swap, since an icon has no text to change). The roster row's overflow
  action (Reset-Combat-State/Teleport-To) renders as an INLINE reveal below the icon row rather than a
  floating popover anchored to the "⋯" icon -- a deliberate deviation from the Figma-literal mechanic:
  this UI runs every ScreenGui at the default `ZIndexBehavior.Sibling`, under which a later sibling
  roster row's opaque background would paint over an earlier row's floating popover for every row
  except the last one visible. An inline reveal has no such escape-the-hierarchy problem (it's just
  another row in the same Panel's own `UIListLayout`, so a following row is pushed down instead of
  drawn over). Every `ActionIcon` takes a `Text` prop that becomes its `Name` and an invisible (fully
  transparent) `Text` value, giving Roblox's accessibility/screen-reader integration and gamepad-nav
  inspection tooling a real label to attach to -- the first accessibility-label convention any
  component in this codebase has needed, since every prior component (`Button`/`Tab`) renders real
  visible text that already served that purpose.
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
- **Built: first-time-player onboarding** (`Screens/Onboarding/{init,Types,Cinematic,RaceSelect,
  Attributes,NameEntry,Confirmation}.lua`, driven by `Client/Onboarding/OnboardingClient.lua`) -- a
  skippable ~19s intro cinematic (staged text reveals over a sky-facing Scriptable camera, held-input
  skip) followed by a mandatory 4-screen character creator (race, attributes, display name, read-only
  confirmation with a held-input commit). A first-time player is detected purely by
  `profile.raceId == nil` (`Server/Systems/CharacterCreationSystem.lua`) -- no new boolean flag, and a
  returning player never sees this again. This is the SECOND deliberate exception to "nothing else
  creates its own root scope" (`UI/init.lua`'s header already carves out the first, for hot-reload
  teardown) -- `OnboardingClient.lua` mounts its own temporary `Fusion.scoped(Fusion)`, runs the whole
  flow, and calls `scope:doCleanup()` BEFORE `UI.Mount()` is ever called, so the two scopes are never
  alive at the same time. The Attributes screen reuses `Components/Bar.lua` for its per-attribute
  meter rather than inventing a new gauge, echoing the hotbar's segmented-gauge read per this doc's
  own "component reuse where it makes sense" guidance. Held-input interactions (cinematic skip,
  Confirmation's commit) are driven by `OnboardingClient.lua`'s own raw `UserInputService` listening,
  deliberately NOT a `Types.KeybindAction` -- this is a one-time session-start interaction, not a
  permanent rebindable action.
- **Not built yet, and why:** Ability System UI *content* (needs `CombatSystem`/`ArtSystem` to
  exist and fire real icon/cooldown/resource state -- the slot shell above is real, what goes in
  each slot isn't), damage numbers and hit feedback (needs `CombatSystem`), lock-on UI (needs
  `CombatSystem`), notifications (needs the relevant systems -- reward, progression, faction -- to
  fire real events), Menu/Inventory/Progression/Lobby screens (need `PlayerDataSystem`,
  `BloodlineManager`, `ArtTreeManager`, `FactionManager` to hold real data). Building any of these
  now would mean fabricating data no server System produces yet -- see this doc's Framework
  section above on server-owns-truth. "Character information" in the Player Status Display is the
  same story.
- **Built since: the Player Status Display's "Level" entry**, which this list previously deferred on
  the grounds that `TierSystem` was an empty `Init()`. It no longer is. `Server/Systems/TierSystem.lua`
  owns the nine-tier ladder (`Shared/TierConstants.lua` holds every threshold and name), promotes off
  `GameplayEvents.MeridianXPAwarded`, persists through `PlayerDataSystem`, and replicates tier
  identity plus the tier's XP window over `Progression_TierUpdated`. `Components/TierBadge.lua`
  renders it at the head of the hotbar -- numeral, name, and a meter it fills from the replicated
  window against `ClientState.MeridianXP`, so the meter advances on every kill rather than only on a
  promotion. That last bit of arithmetic is the one deliberate carve-out from "never computed on the
  client": the server stays authoritative over tier IDENTITY (which its never-demote rule makes
  genuinely underivable from XP alone), and only the fill percentage is computed locally -- see
  `Types.TierUpdatePayload`'s own header for the full reasoning.
- **Shape language -- true cut-corner panels are implemented, not every surface opts in:** see the
  "Built: true cut-corner tile/panel shape" bullet above (`Client/UI/ChamferedSurface.lua`).
  Surfaces that haven't opted into `Chamfered`/haven't been given the treatment yet (Menus' Root
  frame, DevMenu, BugReport, most `Panel.lua` callers) still render `Tokens.CornerRadius =
  UDim.new(0, 0)` sharp rectangles -- that's an intentional per-surface decision each screen makes,
  not a remaining technical gap. A screen that wants the cut-corner treatment passes
  `Chamfered = true` to its `Panel.lua` call (or, for a tile-shaped surface, calls
  `ChamferedSurface.Fill`/`.Stroke` directly the way `AbilitySlot.lua`/`VitalIcon.lua` do) and gets
  an automatic sharp-rect fallback for free if the chamfered textures aren't available in a given
  environment -- see ChamferedSurface.lua's header for the one real deployment gate.
