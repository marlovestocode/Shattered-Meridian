# Intro redesign — state of the work and what's left

Working doc for the Figma-driven UI retheme. Pairs with
`docs/design/intro-redesign-figma-spec.md` (the exact extracted design: palette, type,
frame chrome, both designed screens, motion). Read that first — it is the source of truth
for every value.

Source design: https://www.figma.com/make/uoC0Orq2KHCk49g672WSAT/Modern-UI-Frames-Design
It is a **Figma Make** file (a live React app), not a static design. The spec was extracted
from its compiled CSS + rendered DOM, so the numbers are exact rather than eyeballed.
`get_design_context` on a Make file returns resource links its MCP tools cannot read back —
to re-extract, open the Make URL in a browser, pull the `figmacachedpreview` iframe `src`
(its token expires in ~60s), navigate to it directly, and read `/assets/index-*.css`.

---

## Decisions already made — do not relitigate

Confirmed by the user:

1. **Palette is rethemed game-wide**, not scoped to the intro. Cold blue-grey is gone.
   (The lead designer argued for "diegetic violet" — violet only where the Meridian
   fragment is present. It was put to the user and declined in favour of one identity.)
2. **All five intro stages** get the new language. Figma only designed two (Origin =
   `RaceSelect`, Attributes); Cinematic / NameEntry / Confirmation are extrapolated.
3. **Fonts map to Roblox built-ins now**, routed through `Tokens.Type` so a later swap to
   uploaded font assets is a three-line edit.
4. **Build the UI now, wire attributes afterwards.** See the blocker below.
5. In scope beyond the visual pass: the commit-gesture bug (done), the allocation-wipe bug
   (done), the origin copy rewrite (**done, session 2**), and the point-pool rebalance
   (**done, session 2 — interim version, see below**).

Decisions I made while implementing, which you may overturn but should do so deliberately:

- **Attribute colors do not follow the Figma.** It paints Fortitude blue and MeridianFlow
  violet, but Fortitude *is* posture (amber on the HUD) and MeridianFlow *is* qi (pale
  cyan). Shipping those would spend chargen teaching an association the hotbar contradicts
  30 seconds later. `Tokens.AttributeColor` therefore has VIT/FOR/MER inherit their vital's
  exact hue; MGT/PRS/FLT keep the design's swatches.

**Ruled on by the user, session 2 (2026-07-25):**

6. **Points dial and stat-track tick marks: cut, both.** Confirmed the session 1 lean —
   the dial triple-encoded one integer already covered by the header readout and the pip
   rail; the ticks implied a 10-step scale over a range that corresponds to nothing. The
   pip rail (18 individual pips for the shared pool) was never part of this decision and
   survived unchanged — it isn't redundant the way the dial was.
7. **Phase D: interim only, not the full rebalance.** `TierSystem.lua` is still an empty
   `Init()` with no point-grant mechanism, which rules out deferring points to tier-ups
   this pass. `AttributeBudget.MinPerAttribute` raised 5 → 10; `BonusPoolTotal` stays 18.
8. **Race-aware floor, not a flat one.** Raising `MinPerAttribute` to 10 would have made
   Hollowborn's own default block invalid (`BaseValuePerAttribute + RacePrefills.
   Hollowborn.Vitality` = 9, one below a flat floor). `Constants.CharacterCreation.
   AttributeFloors` is now a precomputed `[RaceId][field] -> number` table — normally
   `MinPerAttribute`, but never higher than that race's own prefilled starting value — read
   by both `CharacterCreationSystem.ValidateAttributeBlock` (now takes a `raceId` param)
   and the Attributes screen's own stepper clamp, so the two can't drift apart.
9. **Button.lua's Primary/Secondary variant: strictly additive.** `Variant` is optional;
   every pre-redesign call site (DevMenu/BugReport/Announcement) that doesn't pass it keeps
   rendering exactly as before. Only onboarding's new CTAs opt into `Variant = "Primary"`/
   `"Secondary"`. Chosen because this session had no way to open Studio and eyeball the
   result — still worth a quick in-Studio glance at those three surfaces to confirm nothing
   visually moved.

---

## The blocker that outranks the redesign

**The six attributes are persisted but inert.** `profile.attributes` is written by
`CharacterCreationSystem` and serialized by `PlayerDataSystem`, and nothing reads it.
Verified: `Vitality`/`MeridianFlow`/`Fleetness` appear only in `Constants.lua`,
`Types.lua`, `PlayerDataSystem.lua`, the onboarding UI, and tests — never in
`CombatSystem`, `HitResolution`, or `Movement`. The `Attributes` hits inside `CombatSystem`
are `Constants.Attributes.BonusWalkSpeed` / `RootControlLocked`, an unrelated Humanoid
namespace. Health and posture come from `Constants.Combat`; walk speed resolves through
`Movement.ComputeDesiredWalkSpeed`.

This matters because the redesign's entire thesis is numeric transparency — live stat
previews, per-stat bars, exact values. The user chose to build the UI now and wire the
attributes after. **Keep `Constants.CharacterCreation.AttributeEffects` honest while that's
true** (the existing "not active yet" phrasing on MeridianFlow is the right register; the
Figma's confident "Max Health" / "Outgoing health damage" copy is not).

---

## What is done and verified

`selene` reports 0 errors across `src/StarterPlayer`, `src/ReplicatedStorage`,
`src/ServerScriptService`. `stylua --check` is clean on all of it. Re-confirmed after
session 2's changes (Phases A–F below) — both commands were re-run against the same three
paths at the end of that session and stayed clean throughout, not just at the end.
**The TestEZ suite has NOT been run** — it needs `run-in-roblox` against Studio, still true
after session 2 (see "Still open" below).

### Docs
- `docs/ui-ux-philosophy.md` — added a supersession note after the Stamina one, following
  that file's own convention (canon above the line stays verbatim; changes land as notes
  below). Covers: the new palette with a before/after table, why vitals moved out of
  `Tokens.Color`, why borders/washes are alpha-derived, the **two shape registers**
  (chamfer = combat tiles; sharp-rect + corner brackets = menu panels), and the FontFace
  move.

### `Tokens.lua` — fully restructured
- `export type Tint = { Color: Color3, Transparency: number }`.
- `Tokens.Color` — violet/bronze. `BorderAccent` → **`AccentPrimary`**; new
  `AccentPrimaryBright`, `AccentSecondary` (bronze).
- `Tokens.VitalColor` — Health/Qi/Posture moved out of `Tokens.Color`. **This is the fix for
  a real collision**: the design's accent is named `--qi` (Meridian-fragment violet) and
  `Tokens.Color.Qi` was the pale-cyan *vital*. Separating the tables makes wiring one to the
  other a compile error instead of a screen of pale-cyan buttons. Vitals keep canon hues.
- `Tokens.AttributeColor` — keyed by `Constants.CharacterCreation.AttributeFields`.
- `Tokens.Border` (`Hairline`/`Standard`/`Lit`/`Accent`) and `Tokens.Wash`
  (`CardResting`/`Inset`/`TrackBase`/`Tick`/`RailScrim`/`FooterScrim`/`AccentFill`/
  `AccentBloom`) — both tables of `Tint`. Deliberately not pre-composited to opaque hexes.
- `Tokens.Radius = { Sharp, Hairline }` replaces the singular `CornerRadius`.
- `Tokens.Control.TouchTargetSize = 44` added.
- `Tokens.Type` — 16 steps across three registers, each `{ Face: Font, Size, Tracking? }`.
  **Field renamed `Font` → `Face`** because it now holds a `Font` datatype for
  `TextLabel.FontFace`. Families derived via `Font.fromEnum(...).Family` (never a hardcoded
  `rbxasset://` path): Cinzel→`Merriweather`, Rajdhani→`TitilliumWeb`,
  JetBrains Mono→`RobotoMono`.
- `Tokens.Motion` — existing `*Spring` presets plus `HoverTween`/`StateTween`/`EnterTween`/
  `FillTween` (`Quart`/`Out`, the closest built-in to the design's cubic-bezier). The table
  comment states the selection rule: spring = tracking a live value, tween = a discrete
  transition with a designed duration.

**Deprecated aliases still in `Tokens.lua`**, kept only so unmigrated files compile and
still pick up the new palette: `Color.BorderSubtle`, `Color.BorderAccent`,
`Tokens.CornerRadius`, and `Type.Display`/`Subheading`/`Caption`.
⚠️ `Color.BorderSubtle` is **pre-composited** (`RGB 40,33,54` = `Border.Standard` over
`Surface`), because its call sites assign a plain `Color3` to a `UIStroke` with nowhere to
put the transparency. Sites migrating off it must take `Border.Standard`'s real Color **and**
Transparency.

### Component + call-site migration
- `Label.lua` — `FontFace = scaleStep.Face`. `LabelScale` union expanded and made
  **disjoint** from `TrackedLabel`'s `TrackedScale`, so under `--!strict` passing a tracked
  step to `Label` is a compile error rather than a silently-untracked label.
- `ActionIcon` / `Button` / `Tab` / `TextField` — `FontFace = Tokens.Type.X.Face`.
- **`HoverLabel.lua` — de-risked, and this was a real landmine.** It called
  `TextService:GetTextSize`, whose third parameter is typed `Enum.Font` and cannot accept a
  FontFace — and the modern replacement `GetTextBoundsAsync` **yields**, which is unsafe
  because that code runs inside a `scope:New` tree build. It now measures reactively via
  `AutomaticSize` + `[Out "AbsoluteSize"]`. Do not reintroduce a synchronous measure.
- **`TrackedLabel.lua` — new.** Roblox has no `letter-spacing` and no RichText tag for it,
  so tracked caps are laid out one `TextLabel` per character over a `UIListLayout` whose
  `Padding` is the tracking. `Text` is a plain string, not `UsedAs<string>` — the run is
  composed at build time. Spaces render as fixed-width spacer Frames. Short caps only.
- Vital colors migrated to `Tokens.VitalColor` at 12 sites.
- Mechanical sweep across **28 files**: `Tokens.CornerRadius`→`Tokens.Radius.Sharp`,
  `Color.BorderAccent`→`Color.AccentPrimary`, `Scale = "Caption"`→`"Detail"`,
  `Scale = "Display"`→`"Title"`.

### The two UX bugs
- **Allocation wipe** (`RaceSelect.lua`) — re-clicking the already-selected origin is now a
  no-op. It previously reset the whole attribute block, so a player who allocated 18 points,
  went Back to re-read the cards, and clicked the card they already had lost everything
  silently. Switching to a *different* origin still resets, which is the intended rule.
- **Commit gesture** (`OnboardingClient.lua` + `Onboarding/Types.lua` + `Onboarding/init.lua`
  + `Confirmation.lua`) — `isHoldGestureInput` accepted MouseButton1/Touch from anywhere on
  screen with no hit-testing, so a held click over empty space (or a resting thumb) for one
  second permanently created the character. Now split into `isHoldGestureKey` (always
  global) and `isHoldGesturePointer` (only honoured when `runHoldGesture` is called *without*
  a `pointerHeld` Value). `ConfirmationProps.CommitPointerHeld` is a new
  `Fusion.Value<boolean>` — the one prop that flows screen → client — written by a real
  `CommitButton` via `GuiObject.InputBegan`/`InputEnded`/`MouseLeave`. `runHoldGesture`
  resets it on return so a Finalize retry can't inherit a stuck press.

---

## Session 2 (2026-07-25) — Phases A–F all done

Everything below was originally written as a forward-looking punch list (Phase A through
Phase F, 22 items). Session 2 built all of it except the three items explicitly called out
as still open at the bottom of this section. Kept here, past tense, as the record of what
each phase actually did — not re-flattened into the original numbered list, so a diff
against the original plan stays legible.

**Phase A — shared components.** `Divider.lua` (`Plain`/`Gradient`/`Flourish`), `Glow.lua`
(concentric `UIStroke` rings, the box-shadow substitute), `Stepper.lua` (`+`/`−` only, as
scoped), `LatticeOverlay.lua` (renders nothing — no texture asset exists yet, see Icon art
below). All four match VitalIcon.lua/StepRail.lua's later "table export, not a bare
function" shape where a sibling needed one of their constants (`Stepper.WIDTH`).

**Phase B — extended existing components.** `CornerBracket.RivetSize` optional.
`Bar.lua` got `Glow`/`FillColorSecondary`, both opt-in — **not** `TickCount`: the user cut
tick marks in the same ruling that cut the points dial (see below), so a prop with zero
callers would have been exactly the speculative surface this file's own header warns
against. `Panel.lua` got `Lattice`/`BracketArmLength` (default unchanged at 12px — every
existing `CornerAccent` caller keeps its current look; new screens pass 16 explicitly) and
now defaults its border to `Border.Standard`'s real Tint instead of the pre-composited
`Color.BorderSubtle`. `Button.lua` got `Variant: "Primary" | "Secondary"?`, strictly
additive (session 2 decision 9 above) — Primary's press cue is border thickness, not the
old press-to-`AccentPrimary` background (already invisible under Primary's own resting
fill).

**Phase C — content.** `AttributeAbbreviations`, `RaceEpithets` (Figma's verbatim), and two
**new** tables not in the original plan's exact names — `RaceWorldLines` and
`RaceCostLines` — replace `RaceHooks` (now `DEPRECATED`, zero remaining callers, safe to
delete outright). Archetype chips dropped. Footer copy is the live blocking reason
("Select an origin to continue" / "4 points unspent"), not "Values persist into Act I" or
"Hover a stat for details" — neither of which this codebase's copy ever actually said, so
there was nothing to delete, only something to not add. No Figma stat blocks imported;
`MaxPerAttribute` (20) used throughout, never 19.

**Phase D — point-pool rebalance.** Interim only (session 2 decisions 7–8 above):
`MinPerAttribute` 5→10, `BonusPoolTotal` unchanged at 18, and a new precomputed
`Constants.CharacterCreation.AttributeFloors[RaceId][field]` table (race-aware floor, fixes
the Hollowborn/flat-floor conflict) read by both `CharacterCreationSystem.
ValidateAttributeBlock` (now takes a `raceId: Types.RaceId` param) and Attributes.lua's own
stepper clamp. `CharacterCreationValidation.spec.lua` updated: every existing
`ValidateAttributeBlock` call now passes a race, the old Min-boundary test's numbers
recomputed off the live constants instead of hardcoded, and four new tests cover the
race-aware floor specifically (Hollowborn's own grandfathered 9, that same block rejected
for Human, still-rejects-going-lower, and a positive prefill NOT raising the floor).

**Phase E — onboarding rebuild.** `CreatorFrame.lua` (the responsive 800×640 shell,
`UDim2.new(1,-Space.XXL*2,...)` + `UISizeConstraint`, exactly as scoped).
`StepRail.lua` (3 steps + a bronze seal — the seal deliberately uses `AccentSecondary`, not
`AccentPrimary`, since Confirmation is the one stage that's actually about permanence, per
`ui-ux-philosophy.md`'s violet/bronze split). Completed steps ARE clickable — this needed
one new signal, `StepRailNavigateRequested` (a single shared `BindableEvent` on
`OnboardingHandle`, not a Handle field the original plan anticipated skipping — firing
`BackRequested` repeatedly to fake a multi-step jump would have visibly desynced from what
the rail promised). No `PointsDial.lua` — cut, see below. `OriginCard.lua` — progressive
disclosure as scoped, but a **single column, not the Figma's 2×2 grid**: Roblox's
`UIGridLayout` forces one uniform `CellSize`, and progressive disclosure means the selected
card is meaningfully taller than the other three — no per-row auto-height the way CSS grid
gives the Figma for free. All five screens (`RaceSelect`/`Attributes`/`NameEntry`/
`Confirmation`/`Cinematic`) rebuilt into `CreatorFrame`; the three undesigned stages follow
the designer direction below, implemented in full including Confirmation's three escape
hatches, the auto-jump-after-two-consecutive-failures logic, and the fracture-out success
beat. `Onboarding/init.lua` uses `CanvasGroup` for the slide-up on **four of five** stage
layers — **not** NameEntry, which stays a plain `Frame` with a Position-only slide (no
fade): NameEntry is the one stage with a live `TextBox`, this session had no Studio access
to verify the handoff's own flagged CanvasGroup/TextBox-focus risk, and the position-only
fallback is the one the handoff itself authorized for exactly this situation. The
CanvasGroup/UIStroke-rendering risk it also flagged is accepted as-is on the other four
layers, unverified — see "Still open" below.

**Phase F.** DevMenu chrome: 3px no-track scrollbars (`Sidebar.lua` + `ContentArea.lua`),
`Tab.lua`'s border migrated off `Color.BorderSubtle` onto `Border.Standard`/`Border.Accent`,
`ABILITY_PREVIEW_ACCENT_COLORS` swaps the two faction colors for `AccentPrimary`/
`AccentSecondary`. Tracked caps on the real tab strip and on `Section.lua`'s title — **not**
on DevMenu's many OTHER `Tab.lua` call sites (Godmode/Flight/Frozen/Invisible/Spectate/
ability-preview-state/triage-status), because several of those pass live, changing text and
`TrackedLabel` can only ever render a string once; `Tab.lua` grew an opt-in `TrackedCaps`
prop instead of a blanket switch. Subheading sweep: all 7 remaining sites resolved (5 to
`CardTitle` — BugReport's Category/Description field labels, DamageNumberLabel's Posture
kind, PostureBreakBanner's and Announcement's own headlines; 2 to `BodyLarge` — the roster
row's player name, the bug-report row's header) and `Display`/`Subheading`/`Caption` deleted
outright from `Tokens.Type` and `Label.LabelScale` now that nothing references them. Mobile
pass, scoped to the handoff's own "Minimum" bullet: `Stepper.lua`'s buttons floor at
`Tokens.Control.TouchTargetSize` (44) on a touch session (`UserInputService.TouchEnabled`,
read once — a stable per-session fact, unlike viewport width); `Tokens.Type`'s three 9px
steps (Eyebrow/Chip/Abbrev) floor at 12px the same way; Attributes.lua's pip rail collapses
to a single `Bar.lua` under a **reactively tracked** `Camera.ViewportSize.X < 600` (this one
genuinely needs to be live — a desktop window can resize past the breakpoint mid-session);
the origin grid was already single-column at every size (see Phase E).

### Still open

- **Icon art.** Unchanged from the original plan — the icon-artist agent never restarted.
  Needed: the hex lattice tile, the divider flourish diamond (currently Frame-composed and
  fine without it), stepper glyphs (also already Frame-composed), the selection dot, six
  attribute glyphs. Only the lattice actually blocks on a real texture — `Panel.lua`'s
  `Lattice` prop and `LatticeOverlay.lua` are both wired and waiting on
  `LATTICE_TEXTURE_ID` in `Panel.lua`.
- **In-Studio eyeball pass — now covers more than the original HUD/DevMenu scope.** Nothing
  in this session was visually verified in Studio (no access). Beyond the original
  `VitalIcon.lua` sheen-gradient note, add to that list: the whole onboarding rebuild (five
  screens, never rendered), the two unverified CanvasGroup risks in `Onboarding/init.lua`
  (TextBox focus — sidestepped for NameEntry, but worth confirming the other four layers
  don't have some other CanvasGroup surprise; UIStroke rendering inside a CanvasGroup —
  accepted as-is, unverified), and Button.lua's Primary/Secondary rollout on DevMenu/
  BugReport/Announcement (should be visually identical to before, since Variant is additive,
  but "should be" isn't "confirmed").
- **Nine combat-feedback sites reading violet** — unchanged, still deliberately left as
  `AccentPrimary` "for now," still an open decision on whether combat wants its own
  `AccentCombat` token.
- **The TestEZ suite has never been run** against any of this session's changes either — it
  still needs `run-in-roblox` against Studio, same as before.

---

## Roblox can't express these — use the sanctioned substitute, don't improvise

| Design | Substitute |
| --- | --- |
| `box-shadow` blur/spread | `Glow.lua` concentric `UIStroke` rings. Nothing else. |
| `filter: blur(60px)` radial blooms | A single linear `UIGradient` wash. **`UIGradient` is linear-only — radial gradients do not exist.** Don't fake one. |
| `inset 0 1px 0` | `UIGradient` on the background whose first keypoint is brighter. |
| Gradient on a border | **This one works** — parent a `UIGradient` to the `UIStroke`. Use it for the flourish rule. |
| Gradient stroke on an arc | Segmented ring, color lerped per segment. Arcs aren't drawable. |
| `clip-path` polygon wipe | `ClipsDescendants` + animated child `Position`/`Size`. The design's own polygon is a bottom-up rectangular reveal, so this is exact. Angled wipes are unavailable. `ClipsDescendants` is disabled by `Rotation`. |
| `letter-spacing` | `TrackedLabel.lua`. No thin-space interpolation. |
| `disabled:opacity-20` on a subtree | Per-property transparency for small controls; `CanvasGroup` only at screen scale. |
| `cubic-bezier(.4,0,.2,1)` | `Quart`/`Out`, pinned in `Tokens.Motion`. |
| Tiled SVG | `ImageLabel` + `ScaleType.Tile`. No runtime SVG. |
| `text-transform: uppercase` | Author the string in caps. |
| `−` U+2212 | ASCII hyphen-minus; glyph coverage is font-dependent. |

⚠️ Every `ScreenGui` here runs `ZIndexBehavior.Sibling`, so a later sibling paints over an
earlier one regardless of `ZIndex` across different parents. The design's layered chrome
(bloom → lattice → content → brackets → rail) must be ordered as **siblings under one
parent**, with `ZIndex` used only within that parent — the pattern `Panel.lua`'s
`AccentOverlay` already follows.

---

## Designer direction for the three undesigned stages

**Cinematic** — no panel, no rail, no chrome at all; the panel's *absence* is what gives its
arrival weight. Cut from 6 lines/19s to 4 lines/~12s. The skip affordance should fade in at
~t=4s, not t=0 — telling the player they may leave before giving them a reason to stay is
backwards. Shorten the skip hold to ~0.6s and differentiate it from the 1.6s commit hold
(right now both gestures have identical language and opposite consequences).
**The one memorable beat, nearly free:** the cinematic's last line and the Origin header are
already the same words — *"What will you be?"*. Make it a **match cut**: the line doesn't
fade, it stays, and the Origin panel builds around it.

**NameEntry** — the only stage where the player *creates* rather than picks. Render the field
as the name (large centred serif, visible caret, single hairline underneath) rather than as a
form input. Beneath it, the identity line assembling live: `KAELEN / FIRMBORN — Heirs of the
Stonepath`. Counter goes bronze and reads `MINIMUM 3` below 3 characters rather than silently
disabling Continue. Add a "Suggest" button — blank-field paralysis is the biggest drop-off
point in any chargen flow — and route suggestions through the same server filter as typed
input.

**Confirmation** — a vow, not a receipt. Compose the character as one statement rather than
seven equal-weight rows. Reuse the Attributes row component with the steppers removed so it
reads as *your* sheet. Three labeled escape hatches (`Change origin` / `Retune attributes` /
`Rename`) instead of one generic BACK — fixing your origin from here is currently three
sequential Back presses. Pair each Finalize failure with the jump that fixes it, and after
two consecutive failures of the same reason, jump automatically. Add a success beat: on
`Success = true`, `fracture-out` everything except the name, hold it alone in the void for
~1.2s, then hand off to the arrival teleport.

**Nothing anywhere in this flow currently tells the player that any of it is permanent** —
and it is: `CharacterCreationSystem` gates purely on `profile.raceId == nil` and there is no
re-spec path in `src/`. Add a bronze permanence line above the commit.

---

## House style — match it

This codebase has an unusually strong convention: **every module opens with a header comment
stating what it Owns and what it Does Not Own**, and non-obvious decisions carry an inline
comment explaining *why*, often naming the alternative that was rejected and the precedent
being followed. Cross-references to other files by name are normal and expected. Match this
density — it is the single most distinctive thing about the repo, and code that doesn't will
read as foreign.

Run `selene src/StarterPlayer src/ReplicatedStorage src/ServerScriptService` and
`stylua --check` on the same paths before declaring anything done. (Running `selene src/`
including `src/Tests` reports ~1110 pre-existing TestEZ-globals errors — that is not your
change.) Two pre-existing `stylua` drifts also exist in `PlayerDataSystem.spec.lua` and
`ContentArea.lua`'s `abilityPreviewStateButton`; leave them or fix them deliberately.
