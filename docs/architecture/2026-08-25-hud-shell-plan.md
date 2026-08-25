# HUD Shell Plan — one player UI out of seventeen independent ScreenGuis

**Date:** 2026-08-25
**Scope:** `src/StarterPlayer/StarterPlayerScripts/Client/UI/` and the driver modules that own its keybinds.
**Method:** read the current tree before proposing anything. Every defect in §2 is a file:line in the
tree as it stands today, not an estimate — two of them are collisions whose own source comments
assert they cannot happen.

---

## 0. Progress tracker

- [x] **Phase 0** — Baseline and guardrails
- [x] **Phase 1** — `Layers.lua` + `Regions.lua`, six panels migrated
- [ ] **Phase 2** — `Surface.lua`, every remaining ScreenGui migrated
- [ ] **Phase 3** — `Chrome.lua` mode + HUD yielding
- [ ] **Phase 4** — `Chrome.lua` Escape stack
- [ ] **Phase 5** — `Reveal.lua`, five entrances unified
- [ ] **Phase 6** — `Notify.lua` + the `TierPromotion` producer

Phases are independently shippable and independently revertable. Each ends at a green gate (§9), and
nothing in a later phase is required to make an earlier one correct.

---

## 1. Executive summary

The token layer is good. The component layer is good. The layout layer landed in August and is good
(`Stack`/`Layer`/`Inset`/`ScreenFrame`, per `2026-08-20-ui-velocity-plan.md` §7).

**The shell layer does not exist.** There are 17 `ScreenGui` creation sites and nothing owns the
questions that span them: who is in front, who owns which corner of the screen, who is allowed to
handle Escape, what happens to the HUD when a modal opens, and how big any of it is at 4K. Each of
those questions is currently answered independently by each screen, in a prose comment, and two of
those comments are already wrong.

This is the same shape as the layout problem that plan solved, and the fix is the same shape too: a
thin layer of shared, boring modules that make the wrong thing hard to write, plus a mechanical
migration of existing screens onto them. It is not a redesign — no screen's visual output should
change except where §2 says it is currently broken.

| # | Gap | Evidence today | Fixed in |
|---|---|---|---|
| 1 | No region ownership | 2 byte-identical position collisions, both commented as impossible | Phase 1 |
| 2 | No z-order ladder | 4 of 17 ScreenGuis set `DisplayOrder`; the rest are mount-order | Phase 1 |
| 3 | `IgnoreGuiInset` inconsistent | set on 3, absent on 6 always-on panels | Phase 2 |
| 4 | Autoscale reaches 2 surfaces of 17 | `ViewportScale` has exactly 2 callers | Phase 2 |
| 5 | HUD never yields | zero `Enabled` gating in `Screens/HUD/init.lua` | Phase 3 |
| 6 | No input arbitration | 16 independent `InputBegan` connections; 5 screens cannot be closed with Escape at all | Phase 4 |
| 7 | Entrance motion hand-rolled or absent | 2 hand-rolled, 1 fade-only, 2 that pop | Phase 5 |
| 8 | Bottom tiles sit under the mobile thumbstick | pre-existing; `IS_TOUCH` and `TouchTargetSize` both already exist | Phase 1, pending §14.5 |
| 9 | No notification channel | 1 bespoke banner, 1 bespoke feed, nothing shared | Phase 6 |

---

## 2. Verified defects

### 2.1 Two panels occupy the same pixels, and both files say they can't

```
DeathFeed/init.lua:114    Position = UDim2.new(1, -Tokens.Space.L, 0, Tokens.Space.L)
BlimpFuel/init.lua:198    Position = UDim2.new(1, -Tokens.Space.L, 0, Tokens.Space.L)

BlimpHelm/init.lua:362        UDim2.new(0, Tokens.Space.L, 1, -Tokens.Space.L + ...)
WeaponInventory/init.lua:376  UDim2.new(0, Tokens.Space.L, 1, -Tokens.Space.L + ...)
```

Both pairs are byte-identical. Neither pair sets `DisplayOrder`, so which one is on top is decided by
`PlayerGui` insertion order — which is mount order in `UI/init.lua`. Fly a blimp and get a kill and
the kill feed and the fuel gauge render into each other.

What makes this worth a module rather than a fix: **each file documents its corner as free.**

- `WeaponInventory/init.lua:479` — *"CarriedResources holds top-left and BlimpFuel top-right, so the
  three corner tiles never collide."* It does not know `BlimpHelm` took bottom-left, or that
  `DeathFeed` took top-right.
- `BlimpHelm/init.lua:356` — *"The hotbar owns bottom-centre and Screens/BlimpFuel owns top-right, so
  this is the corner a console-sized panel can grow downward-anchored in without ever colliding."* It
  does not know about `WeaponInventory`.

Both authors checked. Both checked against a prose list that no mechanism keeps current. A seventh
panel will get this wrong for the same reason, and the review that approves it will read the same
stale comments.

### 2.1a A THIRD left-edge collision, found by screenshot at Phase 0

Not in the original read, because it is not visible in the source the way §2.1's two are — there is no
pair of matching coordinates to grep for. Found by capturing the Phase 0 reference shots:

```
CarriedResources/init.lua:103  AnchorPoint = Vector2.new(0, 0)   Position = UDim2.fromOffset(Space.L, Space.L)
BlimpHelm/init.lua:360         AnchorPoint = Vector2.new(0, 1)   Position -> UDim2.new(0, Space.L, 1, -Space.L + ...)
```

Different anchors, different corners, no byte-identical line — and they still collide. Both are
`AutomaticSize.Y` at `x = Space.L` (widths 160 and 196, fully overlapping horizontally), so the
bottom-anchored helm console grows *upward* until it reaches the top-anchored resources tile. At the
~740px viewport height of a 1366×768 or a windowed 1080p Studio session it gets there, and
`CARRIED / Coal / Water` renders straight over the helm's `MANUAL / rudder / autopilot` column.

It is reachable by ordinary play, not a corner case — carrying fuel to a blimp you are piloting is
the intended loop, and it is the state all three Phase 0 reference shots happened to be in.

**Phase 1 as specced does NOT fix this, and should not pretend to.** `TopLeft` and `BottomLeft` are
two separate stacks; making each internally well-ordered leaves a bottom-anchored stack free to grow
into a top-anchored one on the same edge. §2.1's two collisions are *within* one region and the
region mechanism closes them completely; this one is *between* two regions on a shared edge, and
closing it needs a decision nobody has made yet — see §14.6.

What Phase 1 does change is that the collision becomes describable: it moves from "two panels that
each believe they own a free corner" to "the left edge is oversubscribed at short viewport heights",
which is a statement about a layout with a named owner rather than about two files that never heard
of each other.

### 2.2 `DisplayOrder` is set by 4 of 17 surfaces

Set: `EmoteWheel` 10, `Onboarding` 10, `Loading` 20, `StartMenu` 30. Everything else — HUD,
CombatFeedback, DeathFeed, Announcement, BlimpFuel, BlimpHelm, CarriedResources, WeaponInventory,
ShiftLockCrosshair, and every `ModalScreen` — is at the default 0 and stacks by mount order.

Live consequences: the announcement banner and the combat feedback layer have no defined relationship
to modals; `ShiftLockCrosshair` (mounted late in `UI/init.lua`) sits above every panel mounted before
it; and `EmoteWheel`'s 10 collides with `Onboarding`'s 10 — harmless only because the two are never
simultaneously mounted, which is again a fact no mechanism enforces.

### 2.3 Half the always-on panels are in a different coordinate space

`IgnoreGuiInset = true` on `HUD`, `CombatFeedback`, `StartMenu`. Absent on `Announcement`,
`BlimpFuel`, `BlimpHelm`, `CarriedResources`, `DeathFeed`, `WeaponInventory`.

So `Tokens.Space.L` from the top means one thing for the HUD and `Space.L` plus the 36px inset for the
kill feed. The margins were authored to match and do not.

### 2.4 Autoscale covers 2 surfaces of 17

`ViewportScale.Compute` has exactly two callers: `Components/ModalScreen.lua` and
`Screens/HUD/init.lua`. Every ambient panel is authored in raw pixels with no `UIScale`.

The visible result on a 4K screen: the dock scales to 1.5, and the fuel gauge, weapon rack, helm
console and carried-resources tile sitting next to it do not. `ViewportScale.lua`'s own header names
this as the thing it exists to prevent — *"a second hand-rolled copy would let a modal and the HUD
disagree about how big the same player's screen is, which is visible"* — and the ambient panels are
that disagreement, by omission rather than by a second copy.

### 2.5 The HUD never yields

`Screens/HUD/init.lua` contains no `Enabled` or root-level `Visible` binding. The dock renders at full
opacity behind every modal, through the death overlay, and during the intro cinematic. Nothing can
ask it to step back, because there is no one to ask.

### 2.6 Sixteen input owners, no arbiter — and five screens Escape cannot close

`Blimp`, `BugReport`, `ShiftLock`, `CharacterMenu`, `Attack`, `Grab`, `Defense`, `DevMenu`,
`EmoteWheel`, `KitEditor`, `LiveConsole`, `MoveEditor`, `Run`, `Onboarding`, `Settings` and
`Storybook` each open their own `UserInputService.InputBegan` connection.

Escape is handled by exactly four of them:

| Screen | Escape closes it? | Where |
|---|---|---|
| Settings | yes | `SettingsClient.lua:302` |
| MoveEditor | yes | `MoveEditorClient.lua:581` |
| KitEditor | yes | `KitEditorClient.lua:232` |
| EmoteWheel | yes | `EmoteWheelClient.lua:214` |
| **CharacterMenu** | **no** | — |
| **DevMenu** | **no** | — |
| **BugReport** | **no** | — |
| **LiveConsole** | **no** | — |
| **Storybook** | **no** | — |

Five panels can only be dismissed by re-pressing their own toggle or finding an in-panel close
control. And because the four that do handle Escape each handle it unconditionally, pressing Escape
with two panels stacked closes *both*. There is no shared ordering because there is no shared owner.

The one thing that does work is the seam to build on: `Constants.Attributes.UiModalOpen` is a
**count-backed** boolean published by `ModalScreen.lua:118` off the ScreenGui's real `Enabled`, and
read as a hard gate by `AttackInputClient`, `GrabInputClient`, `DefenseClient` and `BlimpController`.
That is the right pattern with the right owner. The plan extends it; it does not replace it.

### 2.7 Five ambient panels, four different entrance behaviours

| Screen | Entrance | Detail |
|---|---|---|
| `BlimpHelm` | hand-rolled spring | `ENTER_OFFSET = 14`, `entrance` spring at `:172`, baked into a Position `Computed` at `:362` |
| `WeaponInventory` | hand-rolled spring | `ENTER_RISE = 14`, `reveal` spring at `:374`, same shape at `:376` |
| `Announcement` | fade only | `fadeIn` spring at `:66`, no offset |
| `BlimpFuel` | none | `visible` Value at `:110`, pops |
| `CarriedResources` | none | `visible` Computed at `:86`, pops |

The two hand-rolled ones are the *same 14px rise on a spring*, written twice, with two different
spring presets. The other three each made a different call about whether an entrance exists at all.

### 2.8 On touch, both bottom regions sit under Roblox's own controls

`Tokens.lua:22` reads `UserInputService.TouchEnabled` into `IS_TOUCH`, `Tokens.lua:29` floors body
type at 12px on touch, `Tokens.Control.TouchTargetSize = 44` exists, and `Components/Stepper.lua`
sizes its buttons off it. Touch is a supported target — partially, but deliberately.

Roblox's default mobile thumbstick occupies **bottom-left**, and the jump button **bottom-right**.
The region table in §3.2 puts the weapon rack and the helm console in `BottomLeft`. On a phone both
render underneath the movement stick.

This is not a new bug — `WeaponInventory` and `BlimpHelm` already sit there today, so the plan would
be *preserving* it rather than introducing it. But a region layer that hardcodes one inset per corner
is exactly the wrong place to leave it, because it is the one layer that could fix it for every tile
at once. Regions take a per-input-mode inset; see §14.5 for the decision that has to be made first.

### 2.9 No notification channel

`Announcement` is one bespoke centre-top banner. `DeathFeed` is one bespoke top-right list. The
philosophy doc's **Notification Design** section (item acquired, rank change, progression milestone)
has no surface at all, and `ClientState.TierPromotion` — a real, wired, server-driven promotion
event — is consumed only as a colour flare on `TierBadge`. A rank-up currently cannot say so in words
anywhere on screen.

---

### 2.9a The kill feed has no producer, so §2.1's top-right collision is latent, not live

Found at Phase 0 while writing the guardrail spec. `Screens/DeathFeed/init.lua:8` says the kill feed
is *"driven directly by Client/Combat/CombatClient.lua's Combat_KillFeed handler via imperative
Instance.new calls into this Frame"*. That handler does not exist:

```
$ grep -rn "Combat_KillFeed" src/          -> 1 hit, the comment above
$ grep -rn "KillFeedList"   src/          -> 2 hits, both inside DeathFeed itself
$ git log --diff-filter=D -- "*CombatClient.lua"
  cc05003  Rebuild combat as four layers, and let a player throw a punch again
```

`CombatClient.lua` was deleted in the combat rewrite and took the handler with it. `KillFeedList` is
now an empty 320×200 `BackgroundTransparency = 1` Frame that nothing ever writes into — the same
orphaned-by-the-rewrite shape as the hit-stop/hit-flash/knockback configs.

Two corrections to this document follow, and both matter:

1. **§2.1's *"Fly a blimp and get a kill and the kill feed and the fuel gauge render into each
   other"* is not reachable today.** You cannot get a kill feed entry. The two panels really are at
   byte-identical coordinates, but one of them is permanently empty and invisible, so nothing is
   visibly wrong at top-right right now. The collision is real and latent — it fires the day someone
   writes the producer, which is exactly the sort of delayed detonation the region mechanism is for.
   It is still worth fixing first; it is not worth claiming players are hitting it.
2. **The Phase 0 "kill feed entry present" screenshot cannot be captured** and its absence is not an
   oversight.

**Phase 1 migrates the tile anyway, and does not write a producer.** Building one is new content and
belongs to whichever System owns kill attribution, per §13. But the tile must be sized
`AutomaticSize.Y` from a zero height rather than keeping its fixed 200px, or an empty feed would push
the fuel gauge 200px down the moment both share a stack — turning a latent bug into a visible one in
the name of fixing it. That sizing change is the one piece of §2.1's top-right work that is not
purely mechanical.

## 3. The architecture

```
UI/
  Shell/
    Layers.lua      -- the z-order ladder, as named bands
    Regions.lua     -- named screen regions that stack their tiles instead of overlapping
    Surface.lua     -- the one ScreenGui factory, for full-bleed surfaces
    Chrome.lua      -- UI mode, HUD yielding, and the single Escape stack
    Notify.lua      -- one prioritised notification channel
  Components/
    Reveal.lua      -- the shared entrance/exit, Tier 3 of the velocity plan
```

Five modules and one component. None of them render game content. Each replaces something
independently hand-written — and in two cases hand-written wrong — at three or more sites, which is
this codebase's stated bar for a shared module.

### 3.1 `Shell/Layers.lua`

Pure data: a named `DisplayOrder` ladder, spaced so bands have headroom.

```lua
Layers.World        = 100   -- ShiftLockCrosshair, world-anchored reticles
Layers.Regions      = 200   -- the single region host (§3.2) — HUD, ambient tiles, feeds
Layers.Overlay      = 300   -- CombatFeedback, EmoteWheel, death overlay, posture-break banner
Layers.Modal        = 400   -- every ModalScreen / ScreenFrame
Layers.Debug        = 500   -- LiveConsole, ParkourDebug
Layers.Boot         = 600   -- Onboarding, Loading, StartMenu, BlackScreen
```

A `ScreenGui`'s `DisplayOrder` is a `Layers.*` reference or a `Layers.X + n` nudge, never a literal.
`Surface.New` takes the band as a **required** argument with no default, so the ladder cannot be
skipped by forgetting it.

**Modals need an order *within* their band, which one number cannot give them.** Two modals open at
once is a real, documented case — `Constants.Attributes.UiModalOpen`'s own comment cites the Move
Editor over the character menu, and that is why `ModalScreen`'s `openModalCount` is module-scope
rather than per-instance. If every modal takes the same `Layers.Modal`, the two z-fight and the winner
is `PlayerGui` insertion order — which for the `Lazy` screens is *first-open order*, so it varies
between sessions depending on which panel the player opened first.

So `ModalScreen` assigns `Layers.Modal + n` from its own monotonic counter on each open edge, next to
the count it already maintains on that same edge. Last-opened renders on top, which is the only
behaviour a player would predict. The counter resets when the count returns to zero, so `n` cannot
climb across a session into the next band.

### 3.2 `Shell/Regions.lua` — the fix for §2.1

The instinct is a `Claim(region, screen)` that errors on a second claim. **That is the wrong answer
here**, because both top-right claimants are legitimate and both mount unconditionally at boot — an
assert would just fail the boot it was meant to protect.

Regions are **stacks, not slots.** Each named region is one anchored `Frame` with a `UIListLayout`,
and screens contribute *tiles* with a `LayoutOrder` instead of positioning themselves absolutely.

**Every region lives in one shared host `ScreenGui` at `Layers.Regions`, and a region-hosted screen
does not create a `ScreenGui` of its own at all.** This is the part that actually resolves §2.1: if
the kill feed and the fuel gauge sat in top-right regions belonging to two different bands, they would
still overlap — the band ladder would only make the overlap *deterministic*. One host, one top-right
stack, and the two tiles queue instead. It also drops six `ScreenGui`s, each of which is its own
render layer in Roblox.

| Region | Order | Tile | From |
|---|---|---|---|
| `TopLeft` | 10 | Carried resources | `Screens/CarriedResources` |
| `TopCentre` | 10 / 20 | Announcement / notifications | `Screens/Announcement`, `Shell/Notify` |
| `TopRight` | 10 / 20 | Kill feed / blimp fuel | `Screens/DeathFeed`, `Screens/BlimpFuel` |
| `BottomLeft` | 10 / 20 | Helm console / weapon rack | `Screens/BlimpHelm`, `Screens/WeaponInventory` |
| `BottomCentre` | 10 | The dock and its bands | `Screens/HUD` |
| `BottomRight` | — | reserved | — |

Lower order sits closer to the region's anchored edge. Two contracts the region owns:

- **Growth direction is the region's, not the tile's.** A bottom-anchored region grows upward; tiles
  never carry an anchor point or an absolute position.
- **A hidden tile occupies nothing.** The tile declares presence; the region drives both `Visible`
  and a height collapse to zero through `Reveal` (§3.6). Driving both is deliberate — the HUD band
  stack already animates `BountyMarkedBadge` to a true zero height rather than toggling `Visible`
  (`HUD/init.lua`, the `Gap = 0` comment), and whether a `UIListLayout` skips invisible children is
  **not answerable by any test in this repo** (a headless place never resolves `AbsoluteSize`).
  Driving both is correct either way, so the question never has to be settled. Same posture the
  velocity plan took on `UIFlexItem`.

`BottomCentre` is the dock's, and the dock's own band stack is already a region in everything but
name — the migration adopts it rather than rebuilding it.

### 3.3 `Shell/Surface.lua` — one ScreenGui factory

For full-bleed and independent surfaces; region-hosted screens use §3.2 instead.

```lua
Surface.New(scope, {
    Name = "CombatFeedback",
    Layer = Layers.Overlay,
    Scaled = true,               -- default true
})
```

Applies, in one place and identically every time: the `Layers` band, `IgnoreGuiInset = true` (§2.3 —
one coordinate space, chosen once), `ResetOnSpawn = false`, `ZIndexBehavior.Sibling`, the shared
`ViewportScale` `UIScale` (§2.4), and registration with `Chrome`.

**One `ViewportScale.Compute` per root scope**, read by every surface — not one call per surface. Each
call opens its own `ViewportSize` connection, and 17 connections recomputing 17 `Computed`s on every
window resize is exactly the idle-cost pattern the HUD's own cooldown-quantisation comment argues
against.

`ModalScreen.lua` keeps its own root because it owns the modal count and the scrim, but takes its
`ScreenGui` from `Surface.New` like everything else — the count-backed `UiModalOpen` write stays
exactly where it is.

**`Surface` must depend on no singleton, because five of its callers run before `UI.Mount()` does.**
`Main.client.lua` calls `LoadingClient.Run()` and then `IntroClient.Run()` — which blocks through the
entire cinematic and character creator — and only then reaches `UI.Mount()`. `Onboarding` mounts on
its **own temporary Fusion scope**, torn down before the root scope exists (that module's header
explains why). So `Loading`, `Onboarding`, `StartMenu`, `BlackScreen` and `IntroClient` all construct
surfaces in a window where there is no root scope, no region host and no `Chrome`.

`Surface.New(scope, props)` therefore takes its scope as an argument and reads nothing global. Its
`Chrome` registration is optional and absent in that window — which is correct rather than a
concession: the boot screens are what `Chrome` would be reacting *to*, and a boot screen asking the
mode arbiter whether it may draw would be circular.

### 3.4 `Shell/Chrome.lua`

The only module here with behaviour. Three jobs, split across Phases 3 and 4.

**A UI mode**, as a `Fusion.Value` derived from facts that already exist rather than a flag screens
set by hand:

```
Playing | Menu | Cinematic | Dead | Boot
```

`Menu` comes off the existing `UiModalOpen` count. `Dead` comes off `DeathFeed`'s existing state.
`Cinematic` and `Boot` come off `Onboarding`/`Intro`, which already gate themselves. Nothing new is
computed — the same "reflect, never compute" rule `ClientState` keeps, applied to local presentation
state instead of server state.

**HUD yielding** (§2.5): the dock and the region host get one `Chrome`-driven binding. `Menu` dims,
`Cinematic` and `Boot` hide, `Dead` keeps the dock and drops the ambient tiles.

**One Escape stack** (§2.6): `Chrome` owns a single `InputBegan` connection for Escape and a stack of
`{ Name, Close }` entries that screens push on open and pop on close. Escape closes the topmost only.
Screens keep their own *open* keybinds — `M` stays `CharacterMenuClient`'s, `F5` stays
`LiveConsoleClient`'s. What they hand over is the close edge, which is the one every screen currently
gets wrong or omits.

Deliberately **not** a full input router. Combat, movement and parkour input stay where they are,
gated by the Attribute seam they already read. This codebase's rule is that cross-system influence
goes through an Attribute seam, not a require — `Chrome` publishes to that seam rather than becoming
something combat has to require.

### 3.5 `Shell/Notify.lua`

One prioritised queue feeding one `TopCentre` region tile, with a small kind enum (`Progression`,
`Acquisition`, `World`, `Warning`) mapping to the existing `Tokens` palette. One surface, so a rank-up
and a pickup in the same second queue instead of racing for the same corner.

Wired to the one real source that exists today: `ClientState.TierPromotion`. Everything else in the
philosophy doc's Notification Design section stays unbuilt until its owning System publishes real
data — the doc's standing rule, and why this is a channel plus one wired producer rather than a
screen full of invented content.

### 3.6 `Components/Reveal.lua`

Tier 3 of the velocity plan, never started. One component covering the §2.7 table: a spring-driven
offset plus fade, a "keep it mounted until the exit finishes" guard, and the region's zero-height
collapse contract, in one place.

`Tokens.Motion.EnterTween` already exists and is documented as *"a whole screen entering (the design's
slide-up)"* — the offset uses a spring per the philosophy doc's spring/tween split, with
`FlightMath.SpringStep` as the house implementation.

---

## 4. Phase 0 — Baseline and guardrails

**Goal:** be able to prove later phases changed nothing they weren't supposed to.

- [x] Strip the `ParkourConstants.lua` BOM and confirm the suite runs green **before** touching
      anything (per `CLAUDE.md`; a zero-test run is silent). Clean on this checkout; the strip is in
      the build command regardless.
- [x] Record the current suite's pass/fail count as the baseline — recorded in §12, not §10 (that is
      where the placeholder actually sat). **2019 passed, 0 failed.** Read §12: the process exits 1
      on a clean tree for a pre-existing reason, so the exit code is not the gate.
- [~] Capture reference screenshots in Studio. **Partially done, and the gap is recorded rather than
      closed.** Three captured at windowed Studio sizes (~1915×791, ~1919×961, ~1912×786), each with
      the helm console, carried-resources tile, fuel gauge and weapon rack simultaneously live —
      which is what exposed §2.1a. Not captured: 1366×768, 2560×1440, and a kill-feed entry.
      The kill feed one is **not capturable at all** — see §2.9a, nothing produces an entry.
      2560×1440 matters for §2.4 (scale), which is Phase 2's concern, not Phase 1's. What Phase 1
      needs is same-size before/after pairs, and it has them.
- [x] Add `Tests/UI/ShellRegions.spec.lua` **now, failing**. Written slightly differently from the
      sketch here, for a reason found while writing it: it asserts per-screen against a **named tile**
      rather than against every `GuiObject`, because `DeathFeed` legitimately contributes a non-tile
      (its centred death overlay) that must keep placing itself. **11 failures, 2020 passes.**

**Gate:** suite green except the one intentionally-failing new spec. **Met** — 11 failures, all of
them in `ShellRegions.spec`, 2020 passes (the 2019 baseline plus the one new assertion that is
already true: `DeathFeed` owns exactly one surface).

---

## 5. Phase 1 — `Layers.lua` + `Regions.lua`

**Goal:** kill both collisions (§2.1) and give all 17 surfaces a real z-position (§2.2).
**Risk:** low — position and `DisplayOrder` only, no behaviour.

### Build

- [x] `UI/Shell/Layers.lua` — the ladder from §3.1, plus `Layers.IsBand(order)` and
      `Layers.BandOf(order)`. `IsBand` alone was not enough: a legitimate `Layers.Boot + 20` is not a
      band base, so the spec needs the containment check too, and that is also what catches a nudge
      counter overrunning into the next band.
- [x] `UI/Shell/Regions.lua` — the region host `ScreenGui`, the six anchored region frames, and
      `Regions.Mount(scope, playerGui) -> host` plus `host:Add(region, order, tile)`. Split in two
      rather than the single `Regions.Mount(scope, region, order, tile)` sketched here, because the
      host has to be created exactly once and then added to six times — one call doing both would
      have had no way to say which of those it was doing.
- [x] Per-input-mode insets (§14.5, decided). `BottomLeft`/`BottomRight` add
      `Tokens.Control.TouchTargetSize * 3` of bottom clearance on touch. `Tokens.lua`'s `IS_TOUCH` was
      a module-local and not exported; it is now `Tokens.IsTouch`, and `Regions` reads that rather
      than opening a second `UserInputService.TouchEnabled` of its own.
- [~] Verify on a touch device (or Studio's device emulator) that both bottom regions clear the
      controls. **NOT DONE — needs a human at Studio's device emulator**; no test in this repo can
      answer it. Desktop is unaffected by construction: the clearance is added only under `IS_TOUCH`,
      and the desktop inset is the same `Tokens.Space.L` all six screens already used.
- [x] Region host is created once, from `UI/init.lua`, on the existing root scope — `Regions.Mount`
      takes the scope as an argument and never calls `Fusion.scoped`.
- [x] **The host is not memoized at module scope.** It lives on the value `Regions.Mount` returns,
      and `UI/init.lua` holds it on a local. Asserted rather than only commented: `ShellLayers.spec`'s
      "does not survive its scope's teardown" mounts, tears the scope down, mounts again on a fresh
      scope, and requires the two hosts to be different Instances.
- [ ] Same audit on `ModalScreen`'s existing `openModalCount`. **Deliberately left for Phase 2**,
      where this plan already puts the modal ordering counter that lives in the same place — the reset
      and the counter are one edit, and doing half of it here would mean touching `ModalScreen.lua`
      twice for one change. Not forgotten, still true, still a real hot-reload bug.
- [x] Header comment on each, in house style, quoting both stale comments from §2.1 as the
      rationale.

### Migrate — each screen returns a tile, drops its own ScreenGui

- [x] `Screens/CarriedResources` → `TopLeft` / 10
- [x] `Screens/Announcement` → `TopCentre` / 10. Its 152px dodge of the combat-banner band could not
      simply be dropped — that would have put the banner on top of the posture-break banner, which
      belongs to a different surface and is not region-hosted. It became `TopCentre`'s top inset
      (`COMBAT_BANNER_BAND_BOTTOM` in `Regions.lua`), so the banner still lands at exactly 184.
- [x] `Screens/DeathFeed` → `TopRight` / 10. Only the kill feed moves; the death overlay is not a
      tile and keeps DeathFeed's `ScreenGui` until Phase 2 gives it `Layers.Overlay`. The tile is now
      `AutomaticSize.Y` from a zero height and `Visible = false`, per §2.9a — a fixed 200px
      always-visible tile would have pushed the fuel gauge down the screen for a feed that is
      permanently empty.
- [x] `Screens/BlimpFuel` → `TopRight` / 20
- [x] `Screens/WeaponInventory` → `BottomLeft` / **20** (not 10 — see the order note below)
- [x] `Screens/BlimpHelm` → `BottomLeft` / **10** (not 20 — see the order note below)
- [x] Deleted the now-false corner-ownership comments in `WeaponInventory` and `BlimpHelm`. Both are
      quoted in `Regions.lua`'s header and in `ShellRegions.spec` — the only place they still appear
      is where they explain why the mechanism had to exist.
- [x] `UI/init.lua`: region host mounted before any region-hosted screen, header updated.
      **`UIHandles` needed no change, and neither did any driver** — see the note under Verify.

### Verify

- [x] `Tests/UI/ShellRegions.spec.lua` green.
- [x] New `Tests/UI/ShellLayers.spec.lua`. Asserts the ladder's own arithmetic (ordering, a full band
      of headroom between neighbours, band containment for a nudge, and that a pre-ladder literal like
      0 or 10 is NOT mistaken for a band) plus the region host: on the `Regions` band, one `ScreenGui`
      rather than six, all six frames present, tiles stacked, bottom regions reversed, and an unknown
      region name erroring rather than silently dropping a tile. **"Every mounted ScreenGui is in a
      known band" belongs to Phase 2**, not here — thirteen surfaces are still at the default 0, so
      that assertion cannot pass until Phase 2 migrates them.
- [~] Studio: pilot a blimp and trigger a kill — fuel gauge and kill feed stack, never overlap.
      **Cannot be performed**: there is no way to produce a kill feed entry (§2.9a). What IS checkable
      is that the fuel gauge has not moved, which the after-screenshot covers.
- [ ] Studio: pick up a weapon while piloting — rack and helm console stack, never overlap. **Needs a
      human.** This is the one change a player can see, and the whole point of the phase.
- [ ] Screenshot diff against Phase 0 for the three unaffected corners. **Needs a human.**

**No driver changes were needed, and the plan expected some.** §6 warns that Phase 1 changes the
`Mount()` return shape of the six screens and that `AnnouncementClient`, `BlimpController` (three
handles), `WeaponInventoryClient` and any `DeathFeed` caller must be updated in the same commit. They
were not, because the handle types did not change: `Mount` gained a *second return value* rather than
altering the first, so every driver consuming `UIHandles.<Screen>` is untouched and still type-checks.
Only `UI/init.lua` reads the new value. Verified by reading all four drivers rather than assumed —
none of them ever reached for a `ScreenGui` or a position.

The one caller that DID need updating was a spec, not a driver: `Tests/UI/WeaponInventory.spec.lua`
resolved the panel by walking into the screen's `ScreenGui` by name. Its 8 tests failed on the first
post-migration run and are fixed in the same commit. Every assertion in it was about the panel's
contents; none had to change, only how the panel is obtained.

**§14.1 turns out to be load-bearing after all, and the top-right screenshot is what answers it.**
The plan drives both `Visible` and height specifically so it never has to know whether `UIListLayout`
skips invisible children. That holds for a tile's own height — but not for the region's `Padding`,
which a visible zero-height child would still take a share of. The kill feed tile is therefore
`Visible = false` rather than merely zero-tall. If `UIListLayout` does skip invisible children, the
fuel gauge is pixel-identical to before; if it does not, it sits `Tokens.Space.S` (8px) lower. The
after-screenshot at top-right settles it at no extra cost.

**One regression this phase knowingly introduces.** The 14px entrance rise on `BlimpHelm` and
`WeaponInventory` is gone. Both were springs driving the panel's `Position`, and a region tile's
`Position` is overwritten by its region's `UIListLayout` on every layout pass — so they did not
survive the migration and could not have, whatever this plan preferred. `BlimpHelm` keeps its 2%
content scale on the same spring, so it still has an arrival; `WeaponInventory` now appears without
one. Phase 5's `Reveal.lua` is where the offset comes back for all five ambient tiles at once, which
is where this plan already put it.

**THE BOTTOM-LEFT ORDER IS SWAPPED RELATIVE TO §3.2, AND THIS IS WHY.** The table above originally
read `WeaponInventory` 10 / `BlimpHelm` 20. Built that way, screenshotted, and reverted on the
evidence: with the rack anchored to the bottom edge, the helm console is lifted by a rack-height plus
the tile gap, and its header row ends up level with Roblox's own topbar buttons — the panel runs
underneath them. The helm is roughly **650px tall on a ~795px viewport**, so it has no room to give.
It is now 10 (anchored to the edge, exactly where it sat before this phase) and the rack is 20
(floating above it). That also stops the entire console shifting every time a weapon is picked up,
which the original order would have done.

This does **not** fix the left edge; it picks the cheaper collision. The bottom-left stack plus the
top-left tile is more content than a short viewport has room for, whichever way round the two are —
see §14.6, which this is evidence for rather than a resolution of.

**What Phase 1 could not preserve.** The 14px entrance rise on `BlimpHelm` and `WeaponInventory` is
gone. Both were springs driving the panel's `Position`, and a region tile's `Position` is overwritten
by its region's `UIListLayout` on every layout pass — so they did not survive the migration and could
not have, whatever this plan preferred. `BlimpHelm` keeps its 2% content scale on the same spring, so
it still has an arrival; `WeaponInventory` now appears without one. Phase 5's `Reveal.lua` is where
the offset comes back for all five ambient tiles at once, which is where this plan already put it.

**§14.1 answered, by screenshot rather than by test.** The top-right gauge measures at the same
height relative to the viewport before and after — within about a pixel, where a `Tokens.Space.S`
shift would have been eight. So `UIListLayout` does skip children whose `Visible` is false, and the
hidden kill feed tile costs neither height nor a share of the region's padding. Evidence, not proof:
it is a measurement off a screenshot, and the plan's belt-and-braces posture (drive both `Visible`
and height) still costs nothing and should stay.

---

## 6. Phase 2 — `Surface.lua`

**Goal:** one coordinate space (§2.3) and one scale curve (§2.4) across every surface.
**Risk:** low — mechanical, one property set per site.

### Build

- [ ] `UI/Shell/Surface.lua` per §3.3.
- [ ] Hoist `ViewportScale.Compute` to a single call on the root scope; `Surface` and `Regions` both
      read that one value. Assert one connection, not seventeen.
- [ ] `Surface.New` errors when `Layer` is absent — no default band.

### Migrate the remaining ScreenGui sites

- [ ] `UI/Components/ModalScreen.lua:172` → `Layers.Modal` (keeps its own scrim and modal count), plus
      the `Layers.Modal + n` last-opened-on-top counter and the teardown reset from §3.1 / Phase 1
- [ ] Driver signatures: Phase 1 changed the `Mount()` return shape of every region-hosted screen, so
      `AnnouncementClient`, `BlimpController` (three handles), `WeaponInventoryClient` and any
      `DeathFeed` caller are updated in the same commit as the screen they read — not left to a
      follow-up, where a stale handle field is a nil-index at runtime and not a type error
- [ ] `UI/init.lua:173` ShiftLockCrosshair → `Layers.World`, `Scaled = false`
- [ ] `Screens/CombatFeedback/init.lua:168` → `Layers.Overlay`
- [ ] `Screens/EmoteWheel/init.lua:192` → `Layers.Overlay` (retire its `DisplayOrder = 10`)
- [ ] `Screens/HUD/init.lua:457` → `BottomCentre` region tile. **Do this one last.** It is the only
      migration touching a surface with its own `UIScale`, its own hand-scaled bottom margin
      (`HUD/init.lua:466`, a `Computed` that multiplies `Space.L` by the scale because `UIScale` does
      not affect `Position`) and its own band stack. That margin becomes the region's, and the
      hand-scaling goes away with it.
- [ ] `Screens/Loading/init.lua:123` → `Layers.Boot + 20`
- [ ] `Screens/Onboarding/init.lua:305` → `Layers.Boot + 10`
- [ ] `Screens/StartMenu/init.lua:136` → `Layers.Boot + 30`
- [ ] `Intro/BlackScreen.lua:74` → `Layers.Boot + 11`
- [ ] `Intro/IntroClient.lua:148` → `Layers.Boot`
- [ ] `Parkour/ParkourDebug.lua:394` → `Layers.Debug`, `Scaled = false`
- [ ] Retire the `DISPLAY_ORDER` literals and their explanatory comments in `Loading` and `StartMenu`
      — the ladder is the explanation now.

### Verify

- [ ] `ShellLayers.spec` extended to assert **zero** raw `DisplayOrder` literals outside `Layers.lua`.
- [ ] Studio at 2560×1440: every ambient panel now scales with the dock. This is the check that
      §2.4 is actually fixed and no test can perform it.
- [ ] Studio on a platform with the top bar: top-anchored margins match the dock's. (§2.3)
- [ ] `Lazy` boundary intact — DevMenu/MoveEditor/KitEditor/LiveConsole/Storybook still unmounted at
      boot. Assert via the existing boot-debug log, not by opening them.

---

## 7. Phase 3 — `Chrome.lua`: mode and yielding

**Goal:** the HUD can be told to step back (§2.5).
**Risk:** medium — first phase that changes what the player sees at runtime.

### Build

- [ ] `UI/Shell/Chrome.lua` with the five-value mode from §3.4, derived only from existing facts.
- [ ] `Chrome.Mode` is a `Computed`, not a Value anything writes — if a mode needs a fact nobody
      publishes, publish that fact at its own owner rather than letting screens set the mode.
- [ ] Yield bindings on the region host and the dock. Transparency via `Reveal`'s spring if Phase 5
      has landed, otherwise a plain `Tokens.Motion` tween — do not hand-roll a third spring here.
- [ ] Decide and record open question §11.2 (does `Dead` dim or hide the ambient region).

### Wire

- [ ] `Menu` off the existing `UiModalOpen` count — read it, do not add a parallel counter.
- [ ] `Dead` off `DeathFeed`'s existing handle.
- [ ] `Cinematic` / `Boot` off `Onboarding` and `Intro`.
- [ ] `UI/init.lua` constructs `Chrome` after the region host and before any screen registers.

### Verify

- [ ] `Tests/UI/Chrome.spec.lua`: every mode transition; mode is derived, never set.
- [ ] Studio: open the character menu — dock dims, does not vanish, and returns cleanly.
- [ ] Studio: die — dock stays, ambient tiles go per the §11.2 decision.
- [ ] Studio: intro cinematic — dock and region host both hidden, both return.
- [ ] Confirm no `RunService` connection was added (§8 rule 1).

---

## 8. Phase 4 — `Chrome.lua`: the Escape stack

**Goal:** Escape closes the topmost panel, and closes the five it currently cannot (§2.6).
**Risk:** medium — the only phase that changes what a keypress does. Ship it alone.

### Build

- [ ] `Chrome.PushEscape(name, close) -> handle` and `handle:Pop()`, backed by an ordered stack.
- [ ] One `InputBegan` connection for Escape, in `Chrome` and nowhere else.
- [ ] Pop is idempotent and order-independent — a screen closed by its own toggle must pop cleanly
      even if it is not on top.
- [ ] Empty stack means Escape is not consumed, so Roblox's own menu still opens.

### Migrate — remove local Escape handling, push instead

- [ ] `Settings/SettingsClient.lua:302` — note it also matches `ButtonStart`; keep that on the driver,
      only Escape moves. Its keybind-capture mode at `:298` must suppress the stack while capturing.
- [ ] `MoveEditor/MoveEditorClient.lua:581` — `F1` shortcuts overlay stays local; only Escape moves.
      The overlay pushes its own entry so Escape closes it before the editor.
- [ ] `KitEditor/KitEditorClient.lua:232`
- [ ] `Emotes/EmoteWheelClient.lua:214` — also matches `MouseButton2`; that stays local.

### Adopt — screens that had no Escape at all

- [ ] `CharacterMenu/CharacterMenuClient.lua`
- [ ] `DevMenu/DevMenuClient.lua`
- [ ] `BugReport/BugReportClient.lua` — check an open `TextBox` first; Escape should defocus the field
      before it closes the form.
- [ ] `LiveConsole/LiveConsoleClient.lua`
- [ ] `Storybook/StorybookClient.lua`

### Verify

- [ ] `Chrome.spec`: Escape pops exactly one; a non-top close pops correctly; the stack empties.
- [ ] Studio: open Settings, then the character menu. Escape closes the menu only. Escape again closes
      Settings. This is the §2.6 regression in one gesture.
- [ ] Studio: each of the five adopting screens closes on Escape.
- [ ] Studio: Escape with nothing open still opens the Roblox menu.
- [ ] Studio: Escape while rebinding a key in Settings cancels the capture, not the panel.

---

## 9. Phase 5 — `Reveal.lua`

**Goal:** one entrance for all five ambient tiles (§2.7).
**Risk:** low.

- [ ] `UI/Components/Reveal.lua` — spring offset plus fade, direction from the host region, the
      mounted-until-exit-finishes guard, and the zero-height collapse from §3.2.
- [ ] Storybook page — it is a motion component and the gallery is the only place to look at one.
- [ ] Migrate `BlimpHelm` (drop `ENTER_OFFSET`, the `entrance` spring at `:172`, the Position
      `Computed` at `:362`).
- [ ] Migrate `WeaponInventory` (drop `ENTER_RISE`, the `reveal` spring at `:374`, `:376`).
- [ ] Migrate `Announcement` (drop the `fadeIn` spring at `:66`; it gains the offset it lacked).
- [ ] Migrate `BlimpFuel` — gains an entrance it never had.
- [ ] Migrate `CarriedResources` — gains an entrance it never had.
- [ ] Confirm `Reveal` is exactly 0 when at rest, per §10 rule 5.

---

## 10. Phase 6 — `Notify.lua`

**Goal:** one notification channel with one real producer (§2.9).
**Risk:** low — new surface, no migration.

- [ ] `UI/Shell/Notify.lua` — prioritised queue, kind enum, one `TopCentre` tile at order 20.
- [ ] `Notify.Push({ Kind, Title, Detail?, Duration? })`, coalescing duplicates.
- [ ] Queue depth cap with an explicit drop policy — a burst must not build an unbounded backlog.
- [ ] Producer: `ClientState.TierPromotion` → a `Progression` notification reading `From`/`To`. It
      already carries both, which is why the type is a table and not a boolean.
- [ ] Leave `TierBadge`'s promotion flare exactly as it is — the flare is the felt cue, the
      notification is the readable one, and they are not redundant.
- [ ] Storybook page for all four kinds.
- [ ] **Do not** add producers for anything else. Every other Notification Design item is blocked on a
      server System that publishes nothing (§12).

---

## 11. Performance budget

The stated goal is *sleek and fast*, and this layer is where a UI gets slow, so the rules are explicit
and each phase checks them:

1. **Zero idle cost.** No `Shell` module opens a `RunService` connection. `Chrome`'s mode is
   edge-driven off values that already change on edges. The HUD's cooldown `Heartbeat` stays the only
   per-frame connection in the UI tree, and keeps its `next(...) == nil` early-out.
2. **One `ViewportScale` connection for the whole client** (§3.3), not one per surface.
3. **Regions collapse, they don't churn.** A hidden tile stays mounted at zero height. Nothing in the
   shell mounts or unmounts Instances in response to a mode change — that is what makes yielding free.
4. **The `Lazy` boundary is preserved.** DevMenu, MoveEditor, KitEditor, LiveConsole and Storybook stay
   deferred. `Surface.New` must not force a `Lazy` to register a layer — registration happens inside
   the thunk, on first open, or the ~257-Instance deferral in `UI/init.lua`'s header is quietly undone.
5. **No new per-frame `Computed`s downstream of an animated value.** `VitalIcon`'s and `AbilitySlot`'s
   "exactly 0 when nothing is happening" pattern is the standard `Reveal` is held to.
6. **Fewer ScreenGuis.** Phase 1 removes six; each is its own render layer.

---

## 12. Gate — run at the end of every phase

- [ ] Strip the `ParkourConstants.lua` BOM (it comes back; a zero-test run is silent).
- [ ] `selene src/` — 0/0.
- [ ] `stylua` on touched files only, then `stylua --check` on that same set. Tree-wide `--check` is
      not a reliable gate on this branch (CRLF churn).
- [ ] `rojo build test.project.json` + `run-in-roblox` — full output, not piped through `tail`.
- [ ] Reachability: `grep -rn "require(.*Shell" src/` — every new module has a non-zero inbound require
      count from outside its own folder. Bootstrap tracing proves the app starts it, not that a player
      reaches it.
- [ ] Screenshot diff against the Phase 0 baseline.
- [ ] Update §0 and this file's phase checkboxes.
- [ ] One commit per phase. Each phase is meant to be revertable on its own, and that is only true if
      it is one commit — Phase 4 in particular is the one someone will want to back out in isolation.

**One risk already retired, so nobody re-checks it:** `UI/Shell/` needs **no** `test.project.json`
change. `CLAUDE.md` warns that a brand-new top-level folder under `Client/` needs its own `$path`
entry, but `Client/UI` is mapped as a single `$path` covering its whole subtree, so a new folder
*inside* `UI/` is already built. Verified against the current `test.project.json`, not assumed.

**Baseline suite result (recorded at Phase 0, 2026-08-25, `progression-spine`):**
`TestEZ: all 2019 test(s) passed` — 2019 passed, 0 failed.

`run-in-roblox` nonetheless exits **1** on a clean tree, and did so before this plan touched
anything. There is exactly one uncaught error in the run log, and it is an artifact of the headless
test place rather than a failing spec:

```
[Server][NetworkBridge][Error] Timed out waiting for RemoteEvent name="Weapon_InventoryChanged"
ReplicatedStorage.Shared.NetworkBridge:184: Remotes.Weapon_InventoryChanged is not a registered RemoteEvent
Script 'ReplicatedStorage.Shared.NetworkBridge', Line 184 - function GetRemoteEvent
Script 'StarterPlayer.StarterPlayerScripts.Client.FX.CombatAnimator', Line 698
```

`scripts/run-tests.lua`'s client load-check require()s the UI/combat client tree, which pulls in
`FX/CombatAnimator.lua`. That module's trailing `task.spawn` resolves the weapon-inventory remote,
which no System registers in this place, so the spawned thread throws after the 10s
`WaitForChildTimeoutSeconds`. TestEZ never sees it — it happens off the test thread — but Studio
logs it and `run-in-roblox` reflects it in the process exit code.

**So the real gate for every phase of this plan is `all N test(s) passed` in the output, not the
process exit code**, and `grep -c 'Stack Begin'` must stay at exactly **1**. A second uncaught stack
is a regression this plan introduced; exit 1 on its own is not.

---

## 13. What this deliberately does not do

- **No visual redesign.** Every screen renders the same after migration except the two collisions,
  the inset/scale corrections, and the two panels that gain an entrance. Anything else that looks
  different is a migration bug, not a feature.
- **No new content.** No lock-on UI, no damage-type variants, no inventory screen. The philosophy
  doc's Not-Built list stays blocked on its owning server Systems, and this plan does not fabricate
  content ahead of them.
- **No input router.** §3.4. Combat, movement and parkour input are untouched; only the Escape close
  edge is centralised.
- **No fifth combat layer.** `Chrome` publishes to the existing Attribute seam and is read; it does
  not require combat and combat does not require it.
- **No `ClientState` expansion.** UI mode is local presentation state, and `ClientState.lua`'s header
  is explicit that such state belongs to the surface that owns the visual. `Chrome` is that owner.
- **No `EditorTokens` promotion.** The Move Editor's screen-scoped palette stays where it is; that
  file's header explains why, and this plan gives no new reason to move it.

---

## 14. Open questions

1. **Does `UIListLayout` skip invisible children?** Load-bearing for §3.2 only if a region ever relies
   on `Visible` alone. The plan drives both `Visible` and height so it never has to be answered — but
   it is four seconds in the Storybook and worth settling. *Owner: Phase 1.*
2. **Does `Dead` hide the ambient region or dim it?** A design call, not a technical one. Phase 3 has
   to pick one and the philosophy doc does not cover the death state. *Owner: Phase 3.*
3. **Should the Escape stack have a "modal Escape wins over game Escape" rule on gamepad?** No gamepad
   support exists today, so this is deferred rather than designed blind. Settings' existing
   `ButtonStart` handling is the only gamepad path and it stays local. *Owner: deferred.*
4. **Does `BottomRight` have a claimant?** Reserved and empty in §3.2. If nothing wants it by Phase 6,
   drop it rather than leaving a region nobody mounts into.
6. **What gives on a left edge that is oversubscribed?** (§2.1a) `TopLeft` and `BottomLeft` share
   the `x = Space.L` column, both grow by content, and at ~740px of viewport height the helm console
   reaches the carried-resources tile. Regions make this describable but do not resolve it. The
   options, none of them free:

   - **One `Left` region** — merges the two stacks so the layout cannot overlap itself. Contradicts
     the six-region table, and puts the resources tile in the middle of the screen edge when the helm
     is up rather than in the corner where it was designed to sit.
   - **Cap the bottom regions' height** and let the tallest tile scroll or truncate. Truncating a
     helm readout silently is worse than overlapping it visibly.
   - **Make the two mutually exclusive** — hide the resources tile while at the helm. Cheapest, and
     arguably correct on content grounds (the furnace gauge already reports the blimp's stores; the
     carried tile is about what is on your back). A design call, not a layout one.
   - **Leave it.** It is pre-existing and Phase 1 does not worsen it, the same posture §2.8 takes on
     the thumbstick overlap.

   *Owner: unassigned. Deliberately not decided inside Phase 1* — every option above is either a
   change to the decided region table or a content decision, and Phase 1's stated risk is "position
   and `DisplayOrder` only, no behaviour."

5. ~~**Do the bottom regions inset for mobile controls?**~~ **DECIDED 2026-08-25 — per-input-mode
   insets.** (§2.8) `Regions` holds an inset table keyed on `IS_TOUCH`, and the bottom regions clear
   Roblox's default control zones on touch only. Sized off `Tokens.Control.TouchTargetSize`, which
   already exists for this reason. Built in Phase 1 — see that phase's checklist.

   Recorded rather than deleted because the *reason* constrains later work: this was chosen as the
   only option whose cost stays inside `Regions.lua`. A future mobile pass that wants a reflowed dock
   and real control-zone layout is a separate piece of work and should not be grafted onto this table
   — the inset is a clearance, not a mobile layout.
