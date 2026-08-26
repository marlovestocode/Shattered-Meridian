# UI Velocity Plan — what to build so the next screen costs a fraction of this one

**Date:** 2026-08-20
**Scope:** `src/StarterPlayer/StarterPlayerScripts/Client/UI/` — 101 files, 31,166 lines, 36 components, 20 screens
**Method:** written immediately after rebuilding the character menu end to end (`Screens/Menus/`),
from the specific things that cost time during that rebuild. Every claim below is a count taken from
the current tree, not an estimate.

**Status (updated 2026-08-20, same day):** Tier 0 and Tier 1 are **built and migrated**; Tiers 2–4
are not started. See §7 at the bottom for exactly what landed, what the scorecard says now, and the
one claim in here that only a Studio session can confirm.

---

## 1. Executive summary

The component layer is good and the token layer is good. **The layout layer does not exist**, and
that is where the time goes.

Building the character menu took three full passes over the same numbers — not because the design
changed, but because every container in this tree carries its own hand-derived arithmetic for how
tall its children are. One type-scale change invalidates all of it, silently, with no compiler help
and no visible failure until someone opens Studio and squints.

| # | Gap | Cost today | Proposed | Tier |
|---|---|---|---|---|
| 1 | No flex layout — remaining height is hand-computed | 10 sites, 4 named `*_ALLOWANCE` constants, re-derived 3× in one session | `Stack` / `Row` over `UIFlexItem` | 1 |
| 2 | Layouts silently swallow decorative children | Hit 3× in one session; 171 `UIListLayout`s in the tree | `Layer` (flow vs. overlay) | 1 |
| 3 | Nothing can be seen without a full place build | 36 components, **zero** visual coverage | `Storybook` dev screen | 0 |
| 4 | Rows position children at literal pixel offsets | 19 sites, all invalidated by any type change | Same fix as #1 | 1 |
| 5 | Motion tokens exist, menus don't use them | 45 `Tokens.Motion` references, 22 actual `Tween`/`Spring` uses, none in `Screens/Menus` | `Transition` / `Reveal` | 3 |
| 6 | Every editor field is hand-rolled | `PropertyEditor.lua` 1,140 lines; `ContentArea.lua` 1,539 | Schema-driven `Inspector` | 4 |

**The single highest-leverage item is #3**, and it is not close. Everything else on this list is a
day of work whose payoff is measured in future days. The Storybook pays off the moment it exists,
because right now the only way to look at a component is to rebuild a `.rbxl` and open Studio — and
that is why #1, #2 and #4 all survived as long as they did.

---

## 2. What actually cost time

### 2.1 Layout arithmetic is carried by hand

Every scrolling container in this tree computes its own height by subtracting a hand-summed constant
from its parent:

```lua
-- Screens/Menus/ArtsTab.lua
local HEADER_ALLOWANCE = HEADING_HEIGHT * 2 + SLOT_STRIP_HEIGHT + TREE_STRIP_HEIGHT
	+ DESCRIPTION_ALLOWANCE + GAP * 5
...
ScrollArea(scope, { Size = UDim2.new(1, 0, 1, -HEADER_ALLOWANCE) })
```

There are **10** of these. Each one is correct only for one exact set of child heights. Raising
`Tokens.Type.Detail` by a single pixel invalidates every one of them, and nothing anywhere reports
it — the container just clips, or leaves a gap, and you find out by looking.

This is not a Roblox limitation. `UIFlexItem` with `FlexMode = Fill` does exactly this natively, and
it is used **0 times** in the entire tree.

### 2.2 A `UIListLayout` positions *every* GuiObject child

This bug hit three separate times in one session:

- the tab strip's closing rule was swept into the tab row as a fifth flow item, pushing the tabs off
  the panel edge;
- `StatusTag`'s leading edge bar was swept into its own text run;
- the header and footer band rules were inset by the band's `UIPadding` instead of spanning it.

All three have the same shape: a decorative element that must be positioned against the *container*
lands in a frame whose layout owns every child. The fix each time was a nested wrapper frame. That
wrapper is now hand-written in five places and is pure boilerplate.

With **171** `UIListLayout` instances in the tree, this is a recurring bug class, not three
accidents.

### 2.3 You cannot look at anything

There is no way to see a component without building a test place and opening Studio. During this
rebuild I wrote a throwaway `run-in-roblox` script that *constructs* all 24 new components and tabs
so the engine would at least validate every property name — that caught real bugs (see
[`roblox-property-names-are-unchecked`](../../CLAUDE.md)), but it renders nothing and is now deleted.

36 components, zero of them viewable side by side, in any state, ever.

### 2.4 Rows position children at literal pixel offsets

```lua
Label(scope, { Position = UDim2.fromOffset(0, 33), Size = UDim2.new(1, 0, 0, 16) })
```

**19** sites. Every one encodes "one line of 13px text, plus 8px, plus the line above it" as a single
magic number with the derivation lost. Three type passes meant re-deriving all of them three times.

### 2.5 The motion tokens have almost no consumers

`Tokens.Motion` is a well-considered table with a documented spring-vs-tween rule. It is referenced
45 times but only 22 of those reach an actual `scope:Tween`/`scope:Spring`, and **none** of them are
in `Screens/Menus`. Every state change in the character menu is instant: tabs cut, panels appear,
numbers jump. The tokens for doing better already exist and are already tuned.

### 2.6 Editors are hand-rolled per field

`Screens/MoveEditor/PropertyEditor.lua` is 1,140 lines and `Screens/DevMenu/ContentArea.lua` is
1,539, both overwhelmingly "label + control + wiring" repeated per field. Adding one tunable to the
Move Editor is a 5-file change today.

---

## 3. The plan

### Tier 0 — `Storybook` (build this first)

`Client/UI/Screens/Storybook/` — a dev-only screen behind a keybind that mounts every component in
every documented state on one scrollable page, plus a token page: the full type ramp at real size,
every palette swatch on both `Surface` and `Background`, a spacing ruler, and the motion presets
playing on a loop.

Why first: it converts every other item on this list from "reason about it and hope" into "look at
it". It also gives the throwaway construction smoke test a permanent home — the same page that a
human looks at is the page a `run-in-roblox` script can walk to assert nothing errors.

Cost: one day. It is a screen made entirely of components that already exist.

### Tier 1 — layout primitives

**`Stack` / `Row`** — a `UIListLayout` wrapper with a gap token and a `Fill` marker:

```lua
Stack(scope, {
	Gap = Tokens.Space.S,
	Children = {
		SectionHeading(scope, { Text = "Arts", Note = knownNote }),
		treeStrip,
		description,
		Stack.Fill(rowsScrollArea),   -- takes whatever is left; no arithmetic
	},
})
```

Backed by `UIFlexItem { FlexMode = Enum.UIFlexMode.Fill }`. Deletes all 10 remaining-height sites,
all 4 `*_ALLOWANCE` constants, and most of the 19 pixel offsets.

**`Layer`** — separates children a layout arranges from children pinned to the container:

```lua
Layer(scope, {
	Flow = { tabButtons },              -- a UIListLayout owns these
	Over = { bandRule(scope, "Bottom"), closeButton },  -- pinned; the layout never sees them
})
```

Closes the §2.2 bug class by construction rather than by remembering.

**`Inset`** — a padding wrapper, so `UIPadding` stops being something callers hand-assemble four
properties at a time.

### Tier 2 — content primitives

Extracted from shapes that already repeat 3+ times across `Menus`, `DevMenu`, `MoveEditor` and
`Settings`:

| Module | Replaces |
|---|---|
| `EmptyState` | 6 hand-written "nothing here yet, and here's why" labels |
| `ListRow` | the art row, the bounty row, the emote slot card — same anatomy, three implementations |
| `DataGrid` | `UIGridLayout` + cell sizing math, currently retyped per grid |
| `Toolbar` | the slot strip, the tree strip, the tab strip |
| `Field` | label + control + hint + error, the unit `PropertyEditor` needs 40 of |

### Tier 3 — motion

**`Transition`** — mount/unmount fade+slide using `Tokens.Motion.EnterTween`, so a tab switch and a
panel open stop being cuts.
**`NumberFlash`** — a numeral that pulses its own color when its value changes. The character sheet
is full of numbers that move for reasons the player should notice.
**`Reveal`** — staggered entrance for list children, one `Tokens.Motion.StateTween` apart.

This is the tier that makes it *beautiful* rather than merely correct, and it is deliberately last:
motion over a layout that still jumps by a pixel on every type change just animates the jump.

### Tier 4 — `Inspector`

Schema-driven property editing: a table of field descriptors in, a laid-out editor out. The Move
Editor and the DevMenu tuning tabs are the two callers that justify it. Not before Tier 2 — it is
`Field` plus a loop, and building it first means building `Field` badly.

---

## 4. What not to build

- **A general theming engine.** One palette, locked (`Tokens.lua`'s header). A second theme has no
  caller and would double every token's surface area.
- **A responsive grid system.** `ModalScreen.AutoScale` already handles the real problem (a
  fixed-pixel panel on a large display). Breakpoint layouts have one plausible consumer — touch —
  and that is a per-screen decision.
- **A virtualised list.** The longest list in the game is the bounty board, bounded by server
  population. `ScrollArea` + `AutomaticCanvasSize` is correct until something renders 200+ rows.
- **An icon system.** Every glyph here is procedural (`VitalIcon`, `CornerBracket`,
  `CharacterPortrait`) precisely because this repo does not guess at asset ids. That constraint is
  right and should not be engineered around.

---

## 5. Sequencing

| Order | Item | Unblocks |
|---|---|---|
| 1 | `Storybook` | seeing anything; every item below |
| 2 | `Stack` / `Row` / `Layer` / `Inset` | deleting §2.1, §2.2, §2.4 |
| 3 | Migrate `Screens/Menus` onto them | proves the primitives on the newest screen |
| 4 | Tier 2 content primitives | the next screen costs a third of this one |
| 5 | Tier 3 motion | the polish pass |
| 6 | `Inspector` | Move Editor / DevMenu maintenance |

Steps 1–3 are the ones that pay for themselves inside a single feature.

## 6. How we'll know it worked

- `grep -c 'UDim2.new(1, 0, 1, -'` over `Client/UI/` goes to **0**.
- No file in `Screens/` declares an `*_ALLOWANCE` constant.
- Adding a tab to an existing screen touches one file.
- A type-scale change requires re-measuring **nothing**.
- Every component in `Components/` appears in the Storybook, and the construction smoke test walks
  that page instead of a throwaway script.

---

## 7. What actually landed (2026-08-20)

### Built

| Item | Where |
|---|---|
| `Stack` / `Row` / `Fill` | `UI/Components/Stack.lua` |
| `Layer` (flow vs. pinned) | `UI/Components/Layer.lua` |
| `Inset` | `UI/Components/Inset.lua` |
| `ScreenFrame` — **not in the original plan** | `UI/Components/ScreenFrame.lua` |
| Storybook (Tokens / Components / Primitives pages) | `UI/Screens/Storybook/`, F7, Studio-only |
| Storybook driver + keybind | `Client/Storybook/StorybookClient.lua`, `Constants.Debug.Storybook` |

`ScreenFrame` was not on the list and is the largest single thing here. It came out of doing step 3
(migrate `Screens/Menus`) and finding that the thing worth extracting from that screen was not its
use of the primitives — it was **the frame itself**. Five other screens were each hand-rolling a
header band, a tab row, a close button and a status line, which is the same copy-paste that produced
§2.2's three bugs. So the frame is now one component and the screens are its callers.

### Migrated onto it

`Screens/Menus` (tabbed, plus a pinned rail), `Screens/Settings` (tabbed), `Screens/LiveConsole` (its
two log sources became the frame's tabs), `Screens/DevMenu`, `Screens/MoveEditor`, `Screens/KitEditor`
(the last three titled rather than tabbed — they are sidebar-shaped tools with nothing to tab
between). `Screens/BugReport` and `Screens/MoveEditor/ShortcutsOverlay` deliberately still call
`ModalScreen` directly; `Screens/Onboarding` calls `Panel` directly. Reasons in `ScreenFrame.lua`'s
header.

`Stack.Fill` additionally replaced the remaining-height math in `Menus/ArtsTab`, `Menus/BountyTab`,
`Menus/EmotesTab`, `MoveEditor/Sidebar`, `MoveEditor/PreviewViewport`, `KitEditor/PropertyEditor` and
`Onboarding/CreatorFrame`.

### Scorecard

| Criterion | Now |
|---|---|
| `UDim2.new(1, 0, 1, -` count over `Client/UI/` | **0** real sites (two remain: a `-3px` Position nudge in `VitalPill`, and `Stack.lua`'s own header quoting the pattern it replaced) |
| `*_ALLOWANCE` constants in `Screens/` | **0** |
| Adding a tab to an existing screen | one file — a name in that screen's `TAB_NAMES` and a body that reads `tabs.Selected[name]` |
| A type-scale change requires re-measuring | nothing in any migrated container |
| Storybook coverage | ~18 of 36 components. The gap is the ones needing a data fixture (`AbilitySlot`, `ActionIcon`, `VitalIcon`, `Graph`, `DamageNumberLabel`) — listed in `ComponentPage.lua`'s header |
| Construction smoke test | permanent: `Tests/UI/Storybook.spec.lua` mounts the whole gallery, `Tests/UI/ScreenFrameScreens.spec.lua` mounts five of the six migrated screens |

It has already paid: the smoke test's first run caught `ComponentPage` calling `Stepper(...)` on a
module that exports `{ Mount = ... }`. That is precisely the class of error §2.3 says nothing in this
repo could catch.

### The one unverified claim

**`UIFlexItem` with `FlexMode = Fill` is assumed to claim the leftover space.** Its existence, and
that `Stack.Fill` attaches one, are asserted in `Tests/UI/LayoutPrimitives.spec.lua` — but a headless
place has no render pipeline, so `AbsoluteSize` never resolves and whether Fill actually *fills* is
not answerable by any test in this repo. Roblox's own docs describe exactly this use (their example
is a slider bar with fixed labels either side), so this is a low-risk assumption rather than a guess
— but it is load-bearing for every migrated container, and the Storybook's Primitives page exists to
settle it in about four seconds: two Fill stages of different heights with identical children, where
a broken Fill collapses both accented rows to zero.

### Not started

Tier 2 (`EmptyState`, `ListRow`, `DataGrid`, `Toolbar`, `Field`), Tier 3 (motion — still 0 uses in
`Screens/Menus`), Tier 4 (`Inspector`). §4's "what not to build" list stands unchanged.
