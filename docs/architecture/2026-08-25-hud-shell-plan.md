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
- [x] **Phase 2** — `Surface.lua`, every remaining ScreenGui migrated
- [x] **Phase 3** — `Chrome.lua` mode + HUD yielding
- [x] **Phase 4** — `Chrome.lua` Escape stack
- [ ] **Phase 5** — `Reveal.lua`, five entrances unified
- [ ] **Phase 6** — `Notify.lua` + the `TierPromotion` producer

Phases are independently shippable and independently revertable. Each ends at a green gate (§9), and
nothing in a later phase is required to make an earlier one correct.

---

## 1. Executive summary

The token layer is good. The component layer is good. The layout layer landed in August and is good
(`Stack`/`Layer`/`Inset`/`ScreenFrame`, per `2026-08-20-ui-velocity-plan.md` §7).

**The shell layer does not exist.** There are 17 `ScreenGui` creation sites (**18 — see Phase 2
on `Combat/GrabInputClient.lua`, which this count missed**) and nothing owns the
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
| 6 | No input arbitration | 16 independent `InputBegan` connections; ~~5~~ **6** screens cannot be closed with Escape at all (§2.6's Settings row is wrong — see Phase 4) | Phase 4 |
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

**REVISED 2026-08-25, after the cause was found.** The helm was only tall enough to reach the
resources tile because of the `SurfaceTexture` + `AutomaticSize.Y` inflation described in Phase 1's
order note — ~175px of content in a panel resolving to ~710px. Fixed, the two no longer meet at
ordinary viewport heights. This entry stays because the *shape* of the defect is still real (two
regions sharing one screen edge, both growing by content, with nothing arbitrating between them) and
because it is the clearest example in this document of a rendered size being taken for a design fact.
It is no longer a live collision.

**Phase 1 as specced does NOT fix this, and should not pretend to.** `TopLeft` and `BottomLeft` are
two separate stacks; making each internally well-ordered leaves a bottom-anchored stack free to grow
into a top-anchored one on the same edge. §2.1's two collisions are *within* one region and the
region mechanism closes them completely; this one is *between* two regions on a shared edge, and
closing it needs a decision nobody has made yet — see §14.6.

What Phase 1 does change is that the collision becomes describable: it moves from "two panels that
each believe they own a free corner" to "the left edge is oversubscribed at short viewport heights",
which is a statement about a layout with a named owner rather than about two files that never heard
of each other.

### 2.1b The bottom edge oversubscribed itself, at the resolution this UI is authored against

**Found by screenshot 2026-08-25, after Phase 2. FIXED in the same pass as Phase 3, as a separate
commit.** Not a Phase 1 regression and not something the region table got wrong — a new occupant
arrived on an edge and nothing was watching it, which is §2.1's shape a third time.

The armament island (`Screens/HUD/ArmamentIsland.lua`) is pinned at `x = -224` inside the dock band,
outside the `BottomCentre` tile's own bounds, so that the dock cannot be shoved sideways to make room
for it. That is right, and the file's header argues for it well. What nobody costed is where the far
end of it lands:

```
dock width                        870   (measured, not estimated)
viewport                         1366   (ViewportScale.REFERENCE_WIDTH — scale is exactly 1.0 here)
dock left edge      (1366-870)/2 = 248
island left edge      248 - 224  =  24
BottomLeft column          16 .. 236    (Space.L inset + the helm console's 220px panel)
```

212px of a 220px panel, covered. Vertically they coincide too: the island occupies 47..145 above the
bottom edge, the helm console 16..162. So at the reference resolution — the one every pixel in this
UI is authored against, and a very ordinary windowed Studio size — the weapon plate renders straight
through the helm's control legend. It clears at 1920 (island left edge 336, 100px of air) and
collides at anything narrower, which is why it was not caught by the Phase 1 screenshots.

**§2.1a's premise is now live again, for a different reason.** That entry was about `TopLeft` and
`BottomLeft` growing into each other on a shared *vertical* column, and was retracted when the helm's
inflation bug was fixed. This is a *horizontal* version of the same thing between `BottomLeft` and
`BottomCentre`, and unlike §2.1a it is not a short-viewport corner case.

**Fixed in `Regions.lua`, not at either tile.** Both bottom *corner* regions now start above the dock
band rather than in the corner: `DOCK_BAND_CLEARANCE` = `BottomCentre`'s own edge inset (16) + the
dock band's measured reach above it (129 = the key legend's 31 plus the band's 98) + one more edge
inset of air = 161px. The alternatives were moving the island (it is one half of a joint with the
dock and has one owner) or narrowing the helm (a content decision to fix a layout bug), and the
region layer is the one place that can state "another surface draws on this strip" once for every
tile that will ever sit there — which is the same job `COMBAT_BANNER_BAND_BOTTOM` does at `TopCentre`.

`BottomRight` takes the clearance too, though it is empty. The dock's right edge is only 12px clear
of that column at the reference resolution, so the *first* tile to claim the corner would land in the
dock's shadow for exactly the reason the helm landed in the island's.

**Unlike `COMBAT_BANNER_BAND_BOTTOM`, this constant is guarded.** That one's own comment admits "if
either banner's YOffset or its height changes, this has to change with it, and nothing will tell
you." `Tests/UI/ShellRegions.spec.lua` mounts the dock with an island, measures the band's real top
off a live layout pass, and fails naming the new number if either corner stops clearing it.

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

**THE SETTINGS ROW IS WRONG — corrected at Phase 4, and left standing because it is the row a reader
would otherwise trust.** `SettingsClient.lua:302` is inside `beginCapture`'s own `InputBegan` and
cancels a keybind *capture*; the panel itself was toggled by `K` and closed by nothing else. Three
screens handled Escape, not four, and six could not be dismissed with it, not five. See Phase 4's
build notes.

| Screen | Escape closes it? | Where |
|---|---|---|
| ~~Settings~~ | **no** — see above | ~~`SettingsClient.lua:302`~~ |
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
| `BottomLeft` | 10 / 20 | Weapon rack / helm console | `Screens/WeaponInventory`, `Screens/BlimpHelm` |
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

  **THE PARENTHETICAL IS WRONG, corrected at Phase 2 and left standing because it is the sentence
  that stopped anyone checking.** This place resolves `AbsoluteSize` perfectly well once a
  `GuiObject` is parented into `StarterGui` and a `Heartbeat` is stepped — `Tests/UI/Hotbar.spec.lua`
  was already relying on that before this document was written, and `Tests/UI/ShellSurface.spec.lua`
  measures the §2.4 scale that way now. The *conclusion* survives on its own merits (driving both
  costs nothing), and §14.1 was in the end answered by screenshot at Phase 1 anyway.

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

**`Scaled` ended up REQUIRED, with no default** — see Phase 2's build notes. Phase 1 landed first
and collapsed six of the surfaces this default was written for into region tiles, which left
`true` as the minority answer among what remained.

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

**THREE OF THESE SHIPPED, AND THE OTHER TWO ARE UNREACHABLE** — `Main.client.lua` finishes the whole
boot/intro sequence before `UI.Mount()` is called at all, so `Chrome` never exists while a `Cinematic`
or `Boot` surface is up. Corrected at Phase 3 rather than deleted here, because this line is what a
reader would otherwise trust. See that phase's build notes.

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
- [x] `Screens/WeaponInventory` → `BottomLeft` / 10
- [x] `Screens/BlimpHelm` → `BottomLeft` / 20
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

**THE BOTTOM-LEFT ORDER IS §3.2'S AFTER ALL, AND THE DETOUR IS WORTH RECORDING.** It was swapped to
helm 10 / rack 20 for one round, on screenshot evidence: with the rack anchored to the bottom edge
the helm console was lifted clear off the top of the screen, its header row level with Roblox's own
topbar buttons. The reasoning at the time was that the helm is ~710px tall on a ~795px viewport and
therefore has no room to give, and §14.6 was written up as "the left edge is over-budget".

**That was wrong, and wrong in a way worth naming: a bug was read as a constraint.** The helm console
is not a 710px panel. It is a ~175px panel that was opting into `SurfaceTexture = true` on an
`AutomaticSize.Y` frame — the combination `Screens/WeaponInventory/init.lua` had already measured and
documented (`MeridianField`'s root Frame is `Size = Scale(1, 1)` and `Panel.lua` parents it as a
direct sibling of `Content` inside the very frame being auto-sized, so the frame sizes itself from a
child defined as 100% of itself and resolves to roughly the viewport height). Roughly three quarters
of that panel was empty.

Fixed at the call site the same way `WeaponInventory` fixed it, and the original order fits with room
to spare. **§14.6's premise is therefore mostly retracted** — see the revision recorded there.

Two lessons this cost a round-trip to learn, both worth keeping:

- **An unexpected size is a bug until measured otherwise.** The whole "left edge is over-budget"
  conclusion, the order swap, and §14.6's original framing all followed from accepting a panel's
  rendered height as a fact about the design rather than asking why a console with four rows of
  content in it filled most of a screen.
- **`WeaponInventory`'s note said it was "the only SurfaceTexture caller that is also AutomaticSize,
  which is exactly why nothing else in this codebase surfaced it."** `BlimpHelm` was the second, with
  the identical bug, at the time that sentence was written. The claim is corrected in place rather
  than deleted, because it is the sentence that stopped anyone checking.

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

- [x] `UI/Shell/Surface.lua` per §3.3.
- [x] Hoist `ViewportScale.Compute` to a single call on the root scope (`UI/init.lua`); `Surface` and
      `Regions` both read that one value. There is exactly one `Compute` call for the client's
      surfaces now, and one more inside `Components/ModalScreen.lua` that is **not** a surface scale —
      see the `AutoScale` note below.
- [x] `Surface.New` errors when `Layer` is absent — no default band. It also errors on a `Layer` that
      is not inside any band (`Layers.BandOf` returns nil), which is what actually catches the thirteen
      pre-ladder literals rather than only catching a forgotten argument.
- [x] **`Scaled` is required too, and does NOT default to `true` as specced above.** Phase 1 landed
      first and took six of the surfaces that default was written for out of existence — they are tiles
      on one host now. Of what remains, most is full-bleed (where a scale means nothing), a world-space
      reticle, a literal-pixel debug readout, or a modal whose own `AutoScale` prop has owned this
      since before `Surface` existed. `Scaled = true` is the minority answer, and a default that is
      wrong more often than right is worse than no default. The rule that replaced it:
      **a surface is scaled if it draws chrome alongside the dock.**
- [x] `openModalCount`'s teardown reset, deferred here from Phase 1 — done in the same edit as the
      `Layers.Modal + n` counter, which is why it waited. Both are module-scope state in the same file
      with the same hot-reload failure: a Studio reload with a modal open left
      `Constants.Attributes.UiModalOpen` stuck true and the player's fists gone for the session.
- [x] The modal nudge is **clamped as well as reset** (`MAX_MODAL_NUDGE = Layers.Spacing - 1`). Reset
      alone bounds nothing if the player never closes everything: a session that opened 100 modals
      without the count reaching zero would have promoted one into `Layers.Debug`, and a debug overlay
      a panel can cover is the exact failure the ladder's spacing exists to prevent.

### Migrate the remaining ScreenGui sites

**There were 12 sites, not 17.** Phase 1 collapsed six into the single region host, so the list below
is what was actually left. Four lines of the original list were stale by the time this phase ran; each
is marked.

- [x] `UI/Components/ModalScreen.lua` → `Layers.Modal`, plus the `Layers.Modal + n` last-opened-on-top
      counter and the teardown reset. Keeps its own scrim, its own modal count, and `Scaled = false`.
- [x] ~~Driver signatures~~ — **STRICKEN, and Phase 1's own write-up had already struck it.** The
      bullet assumed Phase 1 changed the six screens' `Mount()` return shape. It did not: `Mount`
      gained a *second* return value rather than altering the first, so `AnnouncementClient`,
      `BlimpController`, `WeaponInventoryClient` and the `DeathFeed` caller were untouched and still
      type-check. No work here.
- [x] `UI/init.lua` ShiftLockCrosshair → `Layers.World`, `Scaled = false`. (Line **:196**, not the
      `:173` this list carried — Phase 1 moved it.)
- [x] `Screens/CombatFeedback/init.lua` → `Layers.Overlay`, `Scaled = true`.
- [x] `Screens/EmoteWheel/init.lua` → `Layers.Overlay`, retiring its `DisplayOrder = 10`.
- [x] `Screens/DeathFeed/init.lua` — **NOT ON THE ORIGINAL LIST.** Phase 1 split this screen: the kill
      feed became a `TopRight` tile and the centred death overlay kept a `ScreenGui` of its own
      *specifically because `Surface.lua` did not exist yet*. It is a new `Layers.Overlay` surface, and
      it belongs to this phase because Phase 1 created it.
- [x] `Screens/Loading/init.lua` → `Layers.Boot + 20`, `Scaled = false`.
- [x] `Screens/Onboarding/init.lua` → `Layers.Boot + 10`, `Scaled = false`.
- [x] `Screens/StartMenu/init.lua` → `Layers.Boot + 30`, `Scaled = false`.
- [x] `Intro/BlackScreen.lua` → `Layers.Boot + 11`, `Scaled = false`.
- [x] `Intro/IntroClient.lua` → `Layers.Boot`, `Scaled = false`.
- [x] `Parkour/ParkourDebug.lua` → `Layers.Debug`, `Scaled = false`. This one **pays** for the §2.3
      decision rather than being neutral to it: it is top-anchored, and the one time it had previously
      tried `IgnoreGuiInset = true` its two most important lines went under Roblox's top bar. It reads
      `Surface.TopBarInset()` now instead of dropping the property.
- [x] `Screens/HUD/init.lua` → `BottomCentre` region tile. Done last, as specced.
- [x] `Combat/GrabInputClient.lua` → `Layers.Overlay`. **THE EIGHTEENTH SURFACE, which this document
      never counted.** Not in the 17, not in the 12. It is the one deliberate `Surface.New` exemption
      in the client: hand-built `Instance.new` with no Fusion scope anywhere in the module, and
      creating a session-long root scope in a combat input module for one `TextLabel` would cost more
      than the factory saves. It takes the *band* from `Shell/Layers` and sets `IgnoreGuiInset` by
      hand, so the "no raw `DisplayOrder` literals" assertion holds across the whole client rather than
      across most of it. It used to carry a bare `DisplayOrder = 5`.
- [x] `Shell/Regions.lua` — needed no `DisplayOrder` migration (Phase 1 already set `Layers.Regions`)
      but did need the §2.3 decision applied: the host is built through `Surface.New` now, so it is
      full-bleed like everything else.
- [x] Retired the `DISPLAY_ORDER` literals and their explanatory comments in `Loading` and `StartMenu`.

### The `IgnoreGuiInset` decision, and the one tile it deliberately moves

Phase 1 left the region host without `IgnoreGuiInset` on purpose, so its six margins stayed
byte-identical. Choosing a coordinate space was this phase's call. **Every surface is full-bleed**, and
clearing Roblox's ~36px top bar became a layout problem owned by `Regions` (`Surface.TopBarInset()`,
read from `GuiService` rather than hardcoded, with exactly two readers: the top-anchored regions and
`ParkourDebug`).

**Five of the six ambient tiles do not move.** The host's top-anchored regions add the bar's height
back as part of their edge inset, so at scale 1.0 they render at exactly the 52px they always sat at.
It holds across `ViewportScale`'s whole clamped range — at `MIN_SCALE` 0.8 a `16 + 36` inset still
renders at 41.6px against a 36px bar.

**The announcement banner moves up by 36px, and that is the fix.** `CombatFeedback` has always been
`IgnoreGuiInset = true`; the announcement's host was not. So the two combat banners the announcement
is written to clear were measured from the true top of the screen while the announcement itself was
measured from below the top bar — `184` rendering at `220`, a 36px gap that no line in either file
mentioned. That is §2.3 in one concrete pair of numbers, and 184 is finally the number it claimed to
be. **This is the one visible change in the phase, and it needs the screenshot to confirm.**

### What the plan got wrong about what is testable

**§3.2 says a headless place never resolves `AbsoluteSize`. That is false, and this repo already
depended on it being false.** `Tests/UI/Hotbar.spec.lua`'s "sizes itself to its content" case mounts
into `StarterGui`, steps `Heartbeat` and reads `AbsoluteSize` back — which is how the dock's
full-screen-height bug was caught in the first place. So the **scale half of §2.4 is measured for
real** in `Tests/UI/ShellSurface.spec.lua` rather than deferred to a screenshot: a tile and its edge
margin are asserted to grow by the same multiplier, and a pair of zeroes fails loudly rather than
passing.

The **inset half genuinely is not checkable** — `GuiService` reports a zero gui inset in this place
because no topbar is drawn, so `IgnoreGuiInset` has no observable effect on any measurement here. What
is asserted instead is that the property is set at all, on every surface, from one place. Whether the
margins then *look* aligned against a real 36px bar is a screenshot's job and only a screenshot's.

The §3.2 sentence is corrected in place rather than deleted, for the same reason `WeaponInventory`'s
`SurfaceTexture` claim was in Phase 1: it is the sentence that stopped anyone checking.

### One measurement that decided where the `UIScale` goes

Taken against a real render pass rather than reasoned about, because getting it wrong is invisible
until 1440p: **a `UIScale` parented directly to a `ScreenGui` multiplies its descendants' offsets —
both size and position — while leaving a `Size = UDim2.fromScale(1, 1)` child at exactly the
viewport.** The same `UIScale` one level lower, inside a full-bleed `Frame`, inflates that `Frame` to
1.5× the screen instead.

So the surface-level placement is the one spot where "scale the chrome" and "full-bleed stays
full-bleed" are simultaneously true, which is what lets a single `Scaled` flag serve both a corner
panel and a cinematic backdrop. It also means **an edge margin written as an offset scales for free**
— which is what let `HUD/init.lua`'s hand-multiplied bottom margin go away rather than move. That
margin's comment ("a `UIScale` does not affect `Position`") was true of *its* `UIScale`, which sat on
the band stack; it is not true of one on the `ScreenGui` above it. Three things the HUD stopped
owning: its `ScreenGui`, its `ViewportScale.Compute`, and that margin.

`ModalScreen` keeps a second `ViewportScale.Compute`, and that is not a violation of the one-call rule
— it is the `AutoScale` prop, applied to the *Panel's* own `UIScale`, off by default, and owned by
that component since before `Surface` existed. Making it a surface scale would have resized five
hand-measured panels inside a phase whose stated risk is "one property set per site".

### Verify

- [x] `ShellLayers.spec` + new `Tests/UI/ShellSurface.spec.lua`: **zero** raw `DisplayOrder` literals
      outside `Layers.lua` (a source scan, so it catches the next one too), and every surface the test
      place can mount sits inside a named band.
- [x] Modal ordering asserted in `ShellLayers.spec`: last-opened on top, the nudge restarting once
      everything closes, and the clamp holding however many are opened.
- [x] Suite green — **2055 passed, 0 failed, 1 `Stack Begin`** (baseline 2042 + 13 new). `selene` 0/0.
      `stylua --check` clean on the touched set.
- [x] Reachability: `Shell/Surface.lua` has 11 inbound requires from outside `UI/Shell/`.
- [x] `Lazy` boundary intact — `Surface.New` is never called at boot for DevMenu / MoveEditor /
      KitEditor / LiveConsole / Storybook. Registration happens inside the thunk on first open, so the
      ~257-Instance boot deferral in `UI/init.lua`'s header is undisturbed.
- [ ] Studio at 2560×1440: every ambient panel now scales with the dock. **Needs a human.** The spec
      measures that the mechanism multiplies correctly; it cannot say the result looks right.
- [ ] Studio with the top bar visible: top-anchored margins match the dock's, and the announcement
      banner sits 36px higher than it used to. **Needs a human**, and it is the only check on §2.3.
- [ ] Before/after pair at one window size for the five tiles expected NOT to move. **Needs a human.**

---

## 7. Phase 3 — `Chrome.lua`: mode and yielding

**Goal:** the HUD can be told to step back (§2.5).
**Risk:** medium — first phase that changes what the player sees at runtime.

### Build

- [x] `UI/Shell/Chrome.lua`, derived only from existing facts.
- [x] `Chrome.Mode` is a `Computed`, not a Value anything writes. `Tests/UI/Chrome.spec.lua` asserts
      the absence of a `set` on all three exposed values rather than only commenting it.
- [x] Yield bindings on the region host. Phase 5 has not landed, so the motion is a plain
      `Tokens.Motion.EnterTween` — and it lives in `Regions.lua` on the *goal*, not in `Chrome`,
      which is what leaves `Chrome` testable with no render pass and keeps §11 rule 5 (no `Computed`
      recomputing per frame downstream of an animated value).
- [x] §14.2 decided — see below.

### Wire

- [x] `Menu` off the existing `UiModalOpen` count, read through the Attribute seam
      (`Chrome.ObserveModalGate`). No parallel counter, and no `require` from `Shell/` into
      `Components/`.
- [x] `Dead` off `DeathFeed`'s handle, which gained a `Dead: Computed<boolean>` off the same Value
      that already drives the respawn overlay.
- [x] ~~`Cinematic` / `Boot` off `Onboarding` and `Intro`~~ — **STRICKEN, they are unreachable.**
- [x] `UI/init.lua` constructs `Chrome` after its inputs and before the region host. The plan said
      "after the region host"; it cannot be, because the host is what yields to it. `DeathFeed.Mount`
      moved several blocks earlier for the same reason — a `Mount` and an `Add` are separate calls, so
      the kill feed still joins `TopRight` at order 10 exactly as before.

### Verify

- [x] `Tests/UI/Chrome.spec.lua`: every mode transition in both directions, both orders of the
      Dead/Menu stack, and the no-`set` assertion. Plus one end-to-end case that drives
      `DeathFeed.ShowDeath` and asserts the *mode*, so the two cannot drift apart.
- [x] `Tests/UI/ShellRegions.spec.lua` gained the host half: the four corner regions drop and the two
      centre ones are provably not bound to anything, and the scrim darkens and clears again.
- [ ] Studio: open the character menu — dock dims, does not vanish, and returns cleanly. **Needs a
      human.**
- [ ] Studio: die — dock stays, ambient tiles go. **Needs a human.**
- [x] ~~Studio: intro cinematic~~ — nothing to verify; see below.
- [x] No `RunService` connection added. Both inputs change on edges that already exist (an Attribute
      write, a Fusion Value set); the tween rides Fusion's own scheduler like every existing spring.

### Two modes were dropped, and they were not merely unused

The plan specced `Playing | Menu | Cinematic | Dead | Boot`. `Cinematic` and `Boot` are **not
reachable from anywhere `Chrome` exists.** `Main.client.lua` runs `StartMenuClient.Run()`, then
`LoadingClient.Run()`, then `IntroClient.Run()` — which blocks through the entire cinematic and
character creator — and only *then* calls `UI.Mount()`. Every surface those two modes describe has
been torn down before this module is constructed, and the dock they would hide has not been built.

That also **retracts a clause of §2.5**: "the dock renders at full opacity ... during the intro
cinematic" is false. There is no dock during the intro cinematic.

Declaring them anyway would have meant two branches no session can enter and no spec can drive. The
day something runs a cinematic *after* boot, it publishes that fact at its own owner and this file
grows one `Computed` branch and one spec case.

### §14.2 decided — `Dead` hides the ambient corners, `Menu` dims everything

`Menu` puts a scrim over the whole host (the dock included) and takes nothing away — the plan's own
verify step asks for "dims, does not vanish", and combat input is already hard-gated by
`UiModalOpen`, so nothing behind it is actionable anyway. `Dead` hides the four corner regions and
keeps the dock: the corner tiles describe a world the player is not standing in, while an empty
health bar and a spent hotbar are things a dead player is meant to be looking at.

`TopCentre` yields to neither. It is the announcement channel and, from Phase 6, the notification
channel — a channel a mode can swallow is not a channel.

### A scrim, because a `CanvasGroup` would have clipped the island away

The mechanism is worth recording, because the obvious one is wrong here in a way that only shows up
at the pixels. Roblox offers exactly one way to fade a subtree as a unit — a `CanvasGroup` — and a
`CanvasGroup` **clips its descendants to its own bounds**. `BottomCentre`'s tile deliberately pins
the armament island at `x = -224`, outside the region frame it lives in (§2.1b), so a `CanvasGroup`
region would delete the island from the screen the moment it was introduced. One host-wide
`CanvasGroup` avoids the clipping but cannot do `Dead` at all, which needs per-region control.

A full-bleed `Frame` drawn over the six regions has neither problem, costs one Instance, and dims the
world along with the chrome — which is what an elevated panel wants behind it. It does not swallow
input: a plain `Frame` is invisible to Roblox's hit-testing unless it is `Active` or a `GuiButton`
(`ModalScreen.lua`'s header has the long version).

### `Dead` outranks `Menu`, and the cost is real

The mode is one value, so a player killed with the character menu open reads as `Dead`: the corner
tiles drop (right) and the scrim lifts (wrong — the panel is still up, over an undimmed screen, until
it is closed or the respawn lands). Deriving each binding from the raw facts instead of from the mode
composes correctly and was rejected because it leaves the mode with **no consumer at all**, which is
how a value Phase 4's Escape stack depends on quietly rots before Phase 4 arrives.

---

## 8. Phase 4 — `Chrome.lua`: the Escape stack

**Goal:** Escape closes the topmost panel, and closes the five it currently cannot (§2.6).
**Risk:** medium — the only phase that changes what a keypress does. Ship it alone.

### Build

- [x] `Chrome.PushEscape(name, close) -> handle` and `handle:Pop()`, backed by an ordered stack.
- [x] One `InputBegan` connection for Escape, in `Chrome` and nowhere else.
- [x] Pop is idempotent and order-independent — a screen closed by its own toggle must pop cleanly
      even if it is not on top.
- [x] Empty stack means Escape is not consumed, so Roblox's own menu still opens. **Reworded in the
      code, because the specced claim overstates what a game script can do** — see the notes below.
- [x] **`Chrome.BindEscape(name, isOpen, close)` was added, and is what nine of the ten entries
      actually use.** Not in this plan; why it had to exist is below.
- [x] **A focused `TextBox` declines Escape, in `Chrome` rather than in `BugReportClient`.**

### Migrate — remove local Escape handling, push instead

- [x] `Settings/SettingsClient.lua` — **the plan was wrong about this screen, and it moved to Adopt.**
      §2.6 lists it among the four that "handle Escape", citing the line inside `beginCapture`; that
      line cancels a keybind **capture**, not the panel. See the notes below. The capture now pushes
      its own entry above the panel's, so Escape while rebinding cancels the capture and leaves the
      screen up. `ButtonStart` stayed on the driver.
- [x] `MoveEditor/MoveEditorClient.lua` — `F1` shortcuts overlay stays local; only Escape moves. The
      overlay pushes its own entry so Escape closes it before the editor. The three-layer
      `requestEscape` if-chain is gone; the unsaved-changes arm stayed inside the editor's own entry,
      because an arm is a state of the close rather than a surface the player can back out of.
- [x] `KitEditor/KitEditorClient.lua`
- [x] `Emotes/EmoteWheelClient.lua` — also matches `MouseButton2`; that stays local. Bound off
      `handle.IsOpen` rather than the module-local `isOpenValue`, which that field's own note already
      promises is kept in lockstep with it.

### Adopt — screens that had no Escape at all

- [x] `CharacterMenu/CharacterMenuClient.lua`
- [x] `DevMenu/DevMenuClient.lua` — bound inside `startDevMenu`, not `Start`, which holds a `Lazy`.
- [x] `BugReport/BugReportClient.lua` — the `TextBox` check moved to `Chrome`, per above.
- [x] `LiveConsole/LiveConsoleClient.lua` — bound inside `ensureMounted`: there is no `handle.IsOpen`
      before the first force, and an unmounted console cannot be open, so nothing is lost.
- [x] `Storybook/StorybookClient.lua` — same, on the first toggle press, behind a `bound` flag.
- [x] `Settings/SettingsClient.lua` — **six adopters, not five.** See above.

### Verify

- [x] `Chrome.spec`: Escape pops exactly one; a non-top close pops correctly; the stack empties.
      Eleven new cases, including the pop-before-close ordering and the two-unrelated-panels gesture
      §2.6 describes.
- [x] Suite green — **2093 passed, 0 failed, 1 `Stack Begin`** (baseline 2082 + 11 new). `selene` 0/0,
      `stylua --check` clean on the touched set.
- [x] Reachability: `Shell/Chrome.lua` has 11 inbound requires, 10 of them from outside `UI/`.
- [ ] Studio: open Settings, then the character menu. Escape closes the menu only. Escape again closes
      Settings. This is the §2.6 regression in one gesture. **Needs a human.**
- [ ] Studio: each of the six adopting screens closes on Escape. **Needs a human.**
- [ ] Studio: Escape with nothing open still opens the Roblox menu. **Needs a human.**
- [ ] Studio: Escape while rebinding a key in Settings cancels the capture, not the panel. **Needs a
      human**, and it is the one behaviour here that a wrong answer degrades quietly rather than
      visibly.

### `PushEscape` alone would have rebuilt the bug the mode `Computed` was shaped to avoid

The plan specs one primitive: push on open, pop on close. Written out at nine call sites, that is
nine hand-maintained pairs of edges — and these screens do not have one close path each. The move
editor closes from its toggle key, from an "X" routed through `CloseRequested`, and from a guarded
`requestClose` that sometimes *declines*; the live console closes from a `BindableEvent` the panel
owns; Settings now closes from its toggle and from Escape. A screen with four close paths and three
pops leaves a stale entry that eats the next Escape, and that is the same forgotten-edge failure
`Chrome.lua`'s own header spends four paragraphs arguing a *mode* must not be exposed to. Exposing
the Escape stack to it instead would have been the same mistake one layer down.

So `BindEscape(name, isOpen, close)` derives both edges from the screen's own `IsOpen` — the same
fact its visibility is derived from — and there is no edge to forget. `PushEscape` stayed as the
primitive underneath and has exactly one caller: Settings' keybind capture, whose "am I running" fact
is a nilable `ListeningFor` table in a module with no Fusion scope to make a boolean from, and whose
`beginCapture`/`cancelCapture` genuinely are an exactly-matched pair.

**Ten entries, nine panels.** The two extras are layers, not screens: the move editor's F1 overlay
above the editor, and Settings' capture above Settings. Both were branches of an if-chain inside one
screen's private handler before this, and both are structurally identical to the panel-over-panel
case — which is the argument for a stack rather than a registry keyed by screen.

### §2.6's table is wrong about Settings, and the citation is what makes it worth recording

§2.6 says Settings handles Escape at `SettingsClient.lua:302`, and there is a line there. It sits
inside `beginCapture`'s own `InputBegan`, and what it cancels is a keybind capture. The panel was
toggled by `K` and closed by nothing else. So the pre-Phase-4 count is **three** screens Escape could
dismiss and **six** it could not, and this phase adopted six rather than five.

Worth recording because of what the mis-citation nearly cost: both this document and the phase
written from it treated Settings as a screen whose Escape behaviour needed *relocating*. It needed
inventing. The line number was right and the claim about it was not — which is a worse failure than a
number that has merely drifted, because grepping the line finds something and it looks like
confirmation.

### Escape is not sinkable, so "the empty stack does not consume it" is narrower than it sounds

`Shared/Constants.lua`'s `SettingsToggle` comment already had this: *"this repo never disables
Roblox's own native Escape/Menu overlay"*, which is why the settings toggle is `K`. Roblox opens its
menu on Escape at the CoreGui level, above every game script, and a `UserInputService` handler cannot
stop it. So "Escape closes the topmost panel" has always meant "**and** the Roblox menu opens over the
result" — true of the three handlers this phase replaced, and still true of the ten entries replacing
them. Nothing regressed and nothing improved on that axis, and the plan should not have implied it
would.

What the empty-stack rule does guarantee is that with nothing pushed, this connection does nothing at
all — Escape is the Roblox menu and only that. That is what the spec asserts. The stronger reading,
that an open panel somehow suppresses the native menu, was never achievable.

### The stack is the arbiter, not the mode

`Chrome`'s Phase 3 header said Phase 4 would read `Mode` "to decide whether Escape belongs to a panel
or to Roblox's own menu". It does not, and should not. `Mode` is one value with a precedence (`Dead`
outranks `Menu`), so routing the decision through it would make "killed with a panel open" a case
where Escape does nothing — for no gain. Whether anything is listening is answered by whether the
stack is empty, which is the fact the question was about. Corrected in place in `Chrome.lua`.

### What this phase deliberately did not do

No `ContextActionService`, and no screen's *open* keybind moved. §3.4's "not a full input router"
holds: nine modules handed over the close edge and nothing else. Each still owns its own `InputBegan`
for its own toggle, and combat/movement/parkour input was not touched. The gamepad question (§14.3)
stays deferred — `ButtonStart` remains local to Settings' capture, where it was.

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
2. ~~**Does `Dead` hide the ambient region or dim it?**~~ **DECIDED 2026-08-25 — `Dead` hides the
   four corner regions and keeps the dock; `Menu` dims everything and hides nothing; `TopCentre`
   yields to neither.** Rationale, and the mechanism that forced a scrim rather than a `CanvasGroup`,
   are recorded in Phase 3's build notes. *Owner: Phase 3, closed.*
3. **Should the Escape stack have a "modal Escape wins over game Escape" rule on gamepad?** No gamepad
   support exists today, so this is deferred rather than designed blind. Settings' existing
   `ButtonStart` handling is the only gamepad path and it stays local. *Owner: deferred.*
4. **Does `BottomRight` have a claimant?** Reserved and empty in §3.2. If nothing wants it by Phase 6,
   drop it rather than leaving a region nobody mounts into.
6. **What gives on a left edge that is oversubscribed?** (§2.1a) **LARGELY RETRACTED 2026-08-25.**
   The helm console that this question was built around was not 710px of content — it was ~175px of
   content in a panel inflated by the `SurfaceTexture` + `AutomaticSize` bug (see Phase 1's order
   note). With that fixed, the bottom-left stack and the top-left tile fit on a ~795px viewport with
   room to spare, and none of the options below need choosing today.

   **AND THEN THE EDGE OVERSUBSCRIBED ITSELF ANYWAY, HORIZONTALLY — see §2.1b.** The question was
   right and only its axis was wrong: what reached into `BottomLeft` was not the top-left tile
   growing downward, it was the armament island reaching left out of `BottomCentre`. Answered there
   by the region layer arbitrating the shared strip, rather than by any of the four options below.

   What survives of the original vertical observation, and nothing more: `TopLeft` and `BottomLeft`
   share the `x = Space.L` column and both grow by content, so a tall enough bottom-left stack can
   still reach the top-left tile — on a short viewport, with a future third tile, or if the helm
   grows. That is a thing to watch, not a thing to fix now. The options are kept below for whoever
   hits it for real:

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
