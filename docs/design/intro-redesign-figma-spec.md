# Figma Make redesign — extracted spec (source of truth)

Source: https://www.figma.com/make/uoC0Orq2KHCk49g672WSAT/Modern-UI-Frames-Design
Extracted from the live Make preview build (DOM + compiled CSS), 2026-07-24.
Covers **2 screens**: Step 1 "ORIGIN" (= our `Onboarding/RaceSelect.lua`) and
Step 2 "ATTRIBUTES" (= our `Onboarding/Attributes.lua`).
Cinematic / NameEntry / Confirmation are NOT in the Figma file — they must be
extrapolated from the language below.

---

## 1. Palette (CSS custom properties, verbatim)

| Token | Hex | RGB | Role |
|---|---|---|---|
| `--bg` | `#080610` | 8, 6, 16 | page void |
| `--surface` | `#0d0a16` | 13, 10, 22 | main panel |
| `--surface-2` | `#131020` | 19, 16, 32 | raised |
| `--surface-3` | `#1a162a` | 26, 22, 42 | raised+ |
| `--border` | `#a08cc8` @ 9% (`17`) | 160,140,200 | hairline |
| `--border-mid` | `#a08cc8` @ 18% (`2e`) | 160,140,200 | standard |
| `--border-lit` | `#b4a0dc` @ 32% (`52`) | 180,160,220 | corner brackets / emphasis |
| `--qi` | `#9a88c8` | 154,136,200 | **primary accent (violet)** |
| `--qi-dim` | `#9a88c8` @ 12% | | accent fill |
| `--qi-glow` | `#9a88c8` @ 6% | | accent bloom |
| `--qi-bright` | `#b4a0e0` | 180,160,224 | accent text |
| `--bronze` | `#c4a46e` | 196,164,110 | **secondary accent** |
| `--bronze-dim` | `#c4a46e` @ 12% | | |
| `--text` | `#c8c0d8` | 200,192,216 | primary |
| `--text-sub` | `#8a7fa0` | 138,127,160 | secondary |
| `--text-dim` | `#4a4460` | 74,68,96 | tertiary/disabled |
| `--text-ghost` | `#c8c0d8` @ 30% | | |
| `--danger` | `#a85060` | 168,80,96 | |
| `--success` | `#508870` | 80,136,112 | |
| `--warn` | `#c4a46e` | 196,164,110 | = bronze |
| `--radius` | `2px` | | near-sharp, not fully square |

### Per-attribute colors (new — we have no equivalent today)
| Attr | Token | Hex | RGB |
|---|---|---|---|
| Vitality | `--res-vit` | `#b06868` | 176,104,104 |
| Fortitude | `--res-for` | `#6890a8` | 104,144,168 |
| MeridianFlow | `--res-mer` | `#7868b8` | 120,104,184 |
| Might | `--res-mgt` | `#b89060` | 184,144,96 |
| Pressure | `--res-prs` | `#9868a0` | 152,104,160 |
| Fleetness | `--res-flt` | `#508870` | 80,136,112 |

> **Identity conflict:** current `Tokens.lua` is cold blue-grey
> (`Background #0D1117`, `BorderAccent #4FA8D8`, `Qi #A3E0EB`) and
> `docs/ui-ux-philosophy.md` calls it "locked visual identity."
> This design is a deep-violet void + bronze. That is a hue-family change.

---

## 2. Typography

Three families, all web fonts — **none are Roblox built-ins**:
- **Cinzel** (600/700) — display serif, roman caps. Headings, race names, origin chip.
- **Rajdhani** (300/400/500/600/700) — squared techy sans. Body, labels, buttons. Page default, 15px, `letter-spacing: .01em`.
- **JetBrains Mono** (300/400/500) — all numerals, stat abbreviations, counters.

Scale actually used: `9, 10, 11, 13, 15, 22, 28` px.
Tracking: `.025em` (wide), `.05em` (wider), `.12em`, `.15em`, `.18em`, `.2em`, `.3em`.
Rule observed: **the smaller the text, the wider the tracking.** 9px labels ride `.2em`–`.3em`.

Roblox mapping needed (no SVG/webfont at runtime): closest built-ins are
`Bodoni`/`Garamond`/`Merriweather` for Cinzel, `Jura`/`Gotham` for Rajdhani,
`RobotoMono`/`Code` for JetBrains Mono — or upload the real fonts as assets.

---

## 3. Frame chrome (the "Modern UI Frame" the file is named for)

Outer panel: `max-width: 800px; min-height: 640px;`
```
background: var(--surface);
border: 1px solid var(--border-mid);
box-shadow: 0 2px 0 var(--border), 0 60px 120px rgba(0,0,0,0.7);
```

Layered on it, bottom to top:
1. **Ambient bloom** (behind panel, fixed, non-interactive): two blurred radial
   circles — 600×600 at `top:20% left:30%` `rgba(154,136,200,0.035)`, and
   400×400 at `bottom:20% right:25%` `rgba(196,164,110,0.024)`. Both `blur(60px)`.
2. **Hex lattice overlay** at `opacity: 0.025`, tiled SVG pattern
   `60×69` px, polygon `30,2 58,17 58,52 30,67 2,52 2,17`, stroke `#9a88c8` @ `0.6px`, no fill.
3. **Corner brackets**: four 16×16 px L-shapes at the panel corners, 1px,
   `var(--border-lit)`. (We already have `Components/CornerBracket.lua`.)
4. **Step rail** pinned to top, `py-3`, `border-bottom: 1px solid var(--border)`,
   `background: rgba(0,0,0,0.3)`, height 41px. Content centered, `gap: 20px`:
   - numbered 20×20 box, 10px JetBrains Mono.
     Active: `border 1px var(--qi)`, `color var(--qi-bright)`, `background var(--qi-dim)`.
     Inactive: `border 1px var(--border-mid)`, `color var(--text-dim)`, transparent.
   - label, 10px Rajdhani 600, tracking `.15em`; active `--text-sub`, inactive `--text-dim`.
   - 32×1px `--border-mid` connector between steps.
5. **Divider flourish** (Origin screen header): `1px` gradient rule
   `transparent → var(--border-lit)` on the left, mirrored on the right, with a
   **45°-rotated 6×6 square outline** (a diamond), stroke `var(--qi)` @ `0.8px`,
   centered between them.

---

## 4. Screen 1 — ORIGIN (→ `RaceSelect.lua`)

Header: `px-10 pt-10 pb-8`, flourish rule, then centered
`h1` Cinzel 28px 600 tracking `.025em` `--text` — **"What will you be?"**
`p` 13px `--text-sub`, `max-width: 24rem`, line-height 1.625 —
"Choose your origin. It shapes your beginning, not your end."

Body: `grid-cols-2 gap-4 px-8`, scrolls, `pb-6`. Four cards.

### Origin card — unselected
```
background: rgba(255,255,255,0.016);
border: 1px solid var(--border);
border-radius: var(--radius);
box-shadow: none;
```
### Origin card — selected
```
background: linear-gradient(145deg, rgba(154,136,200,0.07) 0%, rgba(154,136,200,0.02) 100%);
border: 1px solid rgba(154,136,200,0.4);
box-shadow: 0 0 40px rgba(154,136,200,0.06), inset 0 1px 0 rgba(154,136,200,0.08);
```
Transition `all .3s`.

Card internals, top to bottom:
- Row `px-5 pt-5 pb-4`, space-between:
  - left column `gap-1`:
    - name row `gap-2`: **name** Cinzel 600 15px tracking `.025em`
      (`--text-sub` → `--text` when selected);
      **archetype chip** 9px Rajdhani 600 tracking `.18em`, `px-1.5 py-0.5`.
      Unselected: `--text-dim`, transparent bg + transparent border.
      Selected: `--qi-bright`, `background var(--qi-dim)`, `border 1px rgba(154,136,200,0.25)`.
    - **epithet** 11px Rajdhani 300 tracking `.12em` `--text-dim`.
  - right: 16×16 circle, 1px border (`--text-dim` → `--qi` selected). When selected
    it contains a 6×6 dot `background var(--qi)`, `box-shadow 0 0 6px var(--qi)`,
    animated in with `fade-in .2s`.
- 1px divider inset `mx-5`, `var(--border)`.
- `px-5 py-4 gap-3`: description 13px `--text-sub` lh 1.625; then a **flavor quote**
  11px *italic* `--text-dim`.
- **Stat-bias strip** `mx-5 mb-4 px-3 py-2`, `background rgba(255,255,255,0.024)`,
  `border 1px var(--border)`, text 11px JetBrains Mono 300 `--text-dim`,
  e.g. `+3 Fortitude · +2 Vitality · −2 Fleetness`. (Note:真 minus sign `−`, and
  `·` separators padded with double spaces.)
- **6-up stat grid** `grid-cols-3 gap-x-4 gap-y-2.5 px-5 pb-5`. Each cell:
  - row: 9px JetBrains Mono tracking `.05em` `--text-dim` abbreviation (VIT/FOR/MER/MGT/PRS/FLT)
    + right-aligned 10px JetBrains Mono value in that attribute's color @ 80% (`cc`).
  - 2px full-width track `rgba(255,255,255,0.04)`, rounded; fill in the attribute
    color with `box-shadow: 0 0 5px <color>55`, `transition: width .4s`.
    Width = `value / 20` as a percentage (10 → 50%, 13 → 65%, 14 → 70%).

Footer: same as screen 2 (below). Empty-state hint reads
"Select an origin to continue"; CONTINUE disabled until a card is chosen.

### Content in the design (differs from our current copy — see `Shared/Races`)
| Name | Archetype | Epithet | Bias |
|---|---|---|---|
| Human | BALANCED | The Unwritten | No stat bias · Full point allocation |
| Firmborn | DEFENDER | Heirs of the Stonepath | +3 FOR · +2 VIT · −2 FLT |
| Rivenkin | STRIKER | Born of the Fracture Lines | +3 MGT · +2 FLT · −1 FOR |
| Hollowborn | MYSTIC | Vessels of Broken Qi | +4 MER · −2 VIT |

Base block is 10/10/10/10/10/10; Firmborn 12/13/8/9/10/8;
Rivenkin 9/8/9/13/12/12; Hollowborn 8/9/14/9/11/9.

> **The design's numbers do not survive contact with `Constants.CharacterCreation`.**
> - Our real `RacePrefills` are far smaller: Human `{}`, Firmborn `Fortitude +2`,
>   Rivenkin `Might +2`, Hollowborn `MeridianFlow +3, Vitality -1` — a net
>   `RacePrecommittedPoints = 2` each, on a `BaseValuePerAttribute = 10`.
>   The design invents much larger, multi-axis leans (±2 to ±4 across four stats).
> - The design is **internally inconsistent**: Firmborn and Hollowborn's blocks each
>   sum to 60, but Rivenkin's sums to **63**. Our server
>   (`CharacterCreationSystem.ValidateAttributeBlock`) requires every race to reach
>   exactly `TotalBudget = 78`, so an uneven base is not representable.
> - Rivenkin's printed bias string ("+3 Might · +2 Fleetness · −1 Fortitude", net +4)
>   also disagrees with its own printed numbers (VIT−1 FOR−2 MER−1 MGT+3 PRS+2 FLT+2).
> - The design's stat bars are scaled `value / 20` on the Origin card but `value / 19`
>   on the Attributes row. `MaxPerAttribute` is 20; the 19 is a mistake.
>
> Treat the design's origin numbers as **mood, not data**. The chip/epithet/quote
> presentation is the part worth taking; the values must come from `Constants`.

---

## 5. Screen 2 — ATTRIBUTES (→ `Attributes.lua`)

Header `px-10 py-7`, `border-bottom: 1px solid var(--border)`, space-between.

Left column `gap-1.5`:
- eyebrow 9px Rajdhani 600 tracking `.3em` `--text-dim` — "CHARACTER CREATION · STEP 2"
- `h1` Cinzel 22px 600 tracking `.025em` `--text` — "Allocate Your Attributes"
- origin line `mt-1 gap-2`: "Origin:" 11px Rajdhani `--text-dim`;
  name 11px **Cinzel** `--qi`; "— The Unwritten" 11px Rajdhani 300 `--text-dim`.

Right column `gap-6`, the **points dial**:
- 96×96 SVG, rotated −90°, `r=38`, `stroke-width: 3`, `stroke-linecap: round`.
  Track stroke `rgba(255,255,255,0.04)`; progress stroke is a
  **linear gradient `#9a88c8 → #c4a46e`** (violet→bronze), `transition .4s`.
  The arc is a gap-arc: `dasharray` ≈ `172 / 239` with `dashoffset ≈ -33.4`
  (i.e. ~72% of the circle, opening at the bottom).
- centered stack: value 20px JetBrains Mono 500 lh1 `--text`; label 9px Rajdhani 600
  tracking `.2em` `--text-dim` — "AVAIL".
- beside it `gap-2`: "POINTS" 10px Rajdhani 600 tracking `.05em` `--text-dim`;
  "18 / 18 left" 13px JetBrains Mono `--text`; "↺  Reset" 10px Rajdhani tracking `.05em` `--text-dim` (button).

**Pip rail** `px-10 py-3.5`, `border-bottom 1px var(--border)`, `background rgba(0,0,0,0.15)`:
one 14×4 px `rounded-sm` pip per allocatable point (18 of them), `gap-1`, wrapping.
Unspent `rgba(255,255,255,0.06)`, no shadow (spent pips light up — presumably `--qi` + glow).
Right side, 10px JetBrains Mono `--text-dim`: "0 of 18 spent".

**Stat rows**, scrolling, `py-3`, separated by a 1px `var(--border)` rule inset
`margin-left/right: 24px`. Each row:
`border-left: 2px solid transparent` (lights to the attribute color on hover),
`padding: 14px 24px 14px 22px`, `gap: 10px`, `transition all .2s`. Row content `gap-5`:
- abbreviation 10px JetBrains Mono 500, fixed `w-8`, attribute color @ `opacity .8`
- name 13px Rajdhani 600 tracking `.025em`, fixed `w-36` (144px), `--text`
- **track** flex-1, 3px tall: base `rgba(255,255,255,0.04)` rounded;
  fill `linear-gradient(90deg, <color>55, <color>)` with `box-shadow 0 0 6px <color>44`,
  `transition .4s`; plus **9 tick marks** at 10%…90%, each `1×6 px`,
  `rgba(255,255,255,0.06)`, vertically centered. Fill width = `value / 19` (10 → 47.37%).
- description 11px `--text-dim`, fixed `w-52` (208px), **hidden below 1280px**
- stepper `gap-2.5`, right-aligned: two 28×28 buttons,
  `border 1px var(--border-mid)`, `background rgba(255,255,255,0.024)`,
  `color --text-sub`, `disabled:opacity-20`; glyphs are a 9×2 rounded bar (minus)
  and a 9×9 plus. Value between them: `w-9` centered, 14px JetBrains Mono 500,
  **tabular-nums**, `--text`.

Descriptions in the design:
Vitality "Max Health" · Fortitude "Posture capacity + passive regen" ·
MeridianFlow "Qi capacity — inactive until awakening" · Might "Outgoing health damage" ·
Pressure "Outgoing posture damage" · Fleetness "Movement · Dash / Sprint / Slide trim"

---

## 6. Footer (shared by both screens)

`px-8 py-5`, `border-top 1px var(--border)`, `background rgba(0,0,0,0.2)`, space-between.
- Left: hint `p` 11px `--text-dim` ("Hover a stat for details  ·  Values persist into Act I").
- Right `gap-3`, two buttons, both `px-7 py-2.5`, 11px Rajdhani 600, tracking `.2em`, `radius 2px`:
  - **BACK** — `border 1px var(--border-mid)`, `color --text-sub`, no fill.
  - **CONTINUE/CONFIRM** enabled — `background var(--qi)`, `color #0d0a16`
    (i.e. text is the *surface* color, not white), `border 1px var(--qi)`,
    `box-shadow 0 0 24px rgba(154,136,200,0.2)`.
  - **disabled** — `background rgba(255,255,255,0.03)`, `color --text-dim`,
    `border 1px var(--border)`, no shadow.

---

## 7. Motion

```
slide-up     : opacity 0→1, translateY(16px→0)          — screen enter, .35s ease
fade-in      : opacity 0→1                               — selection dot, .2s ease
fracture-in  : opacity 0→1 with clip-path polygon wipe
               (0 100%,100% 100%,100% 100%,0 100%) → full rect  — unused on these
               two screens; reserved for the reveal/cinematic register
qi-pulse     : opacity .5 ↔ 1, symmetric                 — idle accent breathing
```
Durations in use: `.2s` (colors/hover), `.3s` (card state), `.4s` (bar/arc fills),
`.35s` (screen enter). Easing `cubic-bezier(.4,0,.2,1)` default.

Scrollbar: 3px wide, thumb `--border-mid`, radius 2px, no track.
