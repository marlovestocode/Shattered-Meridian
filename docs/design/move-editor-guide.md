# Move Editor — authoring guide

The Move Editor is the in-game, admin-gated tool for authoring and retuning every combat move as data.
It was **rebuilt from nothing on 2026-09-29**, schema included; the section at the end records what
went and why, so nobody rebuilds a deleted feature by accident. The same day it gained its tools batch
(frame data, clip matching, undo, the test bench and hit log, the in-world hitbox and Place mode, bulk
edit, version history, and Studio-only write-to-source) — designed in
`docs/architecture/2026-09-29-move-editor-tools-plan.md`.

**Field help is not duplicated here.** Every hint and every refusal message lives in
`src/StarterPlayer/StarterPlayerScripts/Client/UI/Screens/DevTools/MoveEditor/Copy.lua`, which is what the
UI renders. If this document and that module disagree, `Copy.lua` is right.

---

## Opening it

Press `-` (`Constants.Keybinds.Defaults.OpenMoveEditor`). For a non-admin nothing happens: the client's
first `MoveEditor_Open` is refused, so the screen is never even mounted, and `MoveEditorSystem` re-checks
the whitelist (`Server/Network/AdminGate`) on every remote regardless.

**Opening the editor freezes your character** (`AdminActionSystem.SetFrozen`), and closing unfreezes it.
Test still swings — a frozen character can attack, it just cannot walk.

## The screen

A ScreenFrame modal with three columns:

| Column | What it is for |
|---|---|
| **Moves** (left rail) | Every move the game knows, grouped: Arts, your categories, Custom, one group per roster weapon (collapsed), Standalone. Each row says its type (`MELEE`, `SHOT`, `REALM`). Filter by name, id or group (`Ctrl+F`; **Clear** empties it); `↑` / `↓` step through the rows on show. A bronze chip says `NEW`, `UNSAVED` or `TUNED`. **+ New** asks the type first (Melee, Projectile, Domain) and opens the new move on its Hitbox or Realm tab. |
| **Form** (tabs) | The **move type bar** (`Melee` · `Projectile` · `Domain Expansion`), then the inputs, one concern per tab. Which tabs there are depends on the type (below). Only fields that do something for this move are shown. `Tools` holds what acts on more than one move's inputs: bulk edit, version history, and (Studio) source. |
| **Readout** (right rail) | A pinned bar on top -- the move's name, its saved state, **Save · Test · Undo · Redo** -- that never scrolls; under it the results: top and side hitbox plots, the **effective** timeline (draggable, and a clip scrub), frame data, the server's notes, MORE ACTIONS (Revert, Duplicate, Delete / Reset), the test bench and the hit log. |

The rails are pinned so a result is never a tab switch away from the input that caused it. The panel scales
with the screen and shrinks to fit one smaller than it (a 1366×768 laptop) rather than running off it.

### The move type, and the tabs it gives you (2026-10-01)

A custom move's first question is its **type**, picked in the segmented bar above the tabs. It is not a
field: the type *is* the blocks the move carries (a `Projectile` block, a `Domain` block, or neither), so
choosing one seeds its block and drops the others' (and any grab — neither a projectile nor a realm may
grab). Switching is an ordinary edit: undo brings back the block it dropped. A weapon (Default) stage is
always melee and shows no bar.

| Type | Tabs |
|---|---|
| Melee, Projectile | `Hitbox` · `Timing` · `Impact` · `Presentation` · `Identity` · `Tools` |
| Domain Expansion | `Realm` · `Timing` · `Presentation` · `Identity` · `Tools` |

The **Realm** tab has its own sub-tab bar: `Core` (clock, cost, governs) · `Boundary` · `Effects` · `Law` ·
`Clash` (2026-10-07; these were five top-level tabs, which left nine labels sharing the strip). A refusal
still lands you on the page its field is on.

A tab the type does not have is not offered; if you were on it, the editor shows the first tab that is,
and brings you back to it if the move changes back.

### Sections

Every tab is a run of **sections**: a bronze heading you click to fold (`Hide` / `Show`), with a one-line
**summary** of what is inside opposite it (`Box  W 4  H 5  L 5`, `0.30 / 0.20 / 0.30  ·  0.8s cd`), so a
folded section still answers "what is this set to". A short closed choice (the 15 shapes, a spread
pattern, an anchor) is a row of **chips** — every option on screen, one press — instead of a dropdown;
long lists (rule kinds) stay dropdowns. Every number is a **compact slider**: label, unit and value on one
line, the step buttons and a full-width slider on the next (click the value to type it; the wheel, Shift
×10 and Alt ÷10 work as before; a gamepad nudges a selected slider with the DPad), and every value is
snapped to the field's own precision.

**Nothing is built before you look at it.** A tab is built the first time you open it, and a section the
first time it is open and showing — a realm with two effects has built two effects' fields, not six. The
Presentation tab is sixteen such sections, one per moment, folded, each saying `default` or `N set`.

**Hints are on demand.** The line under the form (the help strip) shows what the field under your pointer
does — or the one a gamepad has selected, or the text box you are typing in. **Show hints** (right of the
strip) draws every hint under its field instead.

**Changed fields are marked.** A bronze dot left of a field means it differs from the saved move. Press the
dot to put the saved value back — one ordinary edit, so Undo brings yours back. A never-saved move has no
dots.

**Ids are picked, not typed.** An art's prerequisite, a realm effect's move and a clash override's realm
are chosen from the move list (a search by name or id; a Volley only offers projectile moves, an override
only realms). An id that names nothing the editor knows shows in the warning colour. Category offers the
categories already in use under its box. A colour field has a swatch and a palette (Default, and None where
the field allows it); a sound id and the clip's animation id have **Play**.

## Custom moves vs. weapon (Default) moves

| | **Custom** | **Weapon / standalone (Default)** |
|---|---|---|
| Lives in | `MoveRegistryManager` + DataStore record `Move_<id>` | `CombatConstants` / the weapon roster, projected by `DefaultMoveRegistry` |
| Edited through | the registry | an **override layer** on top of the built stage — the stage table itself is never written |
| Persisted as | the whole move | `DefaultOverride_<id>` (only when it differs from the built move) |
| Deletable | yes | no — **Reset to default** drops the override |
| Editable | everything | shape, dimensions, offset/rotation, timing, damage, posture, max targets |
| Fixed by the weapon/stage | — | name, anchor (Blade vs body box), clip, power level, feintability, no knockback/grab |

A custom move is reachable in play **only if it is an art** (Identity tab → "This move is an art"): a
hotbar slot can only hold an art. The readout says so in its notes for every custom move that is not.

## Melee moves

The Hitbox tab, for a melee move, is three sections:

- **VOLUME** — *Start from* a preset (Fist, Jab, Thrust, Slash, Sweep, Spin, Cleave, Smash, Dome, Breath,
  Funnel, Lance, Burst, Egg — each sets the shape, its size and how far in front of the body it sits, and
  nothing else), the 15 **shape** chips (Box, Sphere, Capsule, Cylinder, Cone, Beam, Arc, Ellipsoid,
  Hemisphere, Frustum, Pyramid, Wedge, Crescent, Cross, Pillar), only the measurements that shape reads —
  under the name that shape gives them (a Crescent's *Bite radius* and *Bite offset*, a Cross's *Bar
  half-width*, a Frustum's *Near* and *Far radius*) — and a *Scale* row (×0.5 ×0.8 ×1.25 ×2, every
  measurement but the angle, clamped to the limits).
- **PLACEMENT** — the anchor (Body / Right hand / Left hand / Weapon), the offset (**Right**, **Up**,
  **Forward** — forward is plus; the engine's CFrame stores it as −Z, the form flips it) and rotation,
  *Place in world* and *Show on my character*.

Each *Start from* chip says what the preset is (its label and note) on a line under the row while the
pointer is on it.
- **TARGETS** — how many bodies one swing may hit.

What the thrower is held to is the Timing tab's **COMMITMENT** (lock movement while winding up / while
active, feintable), and the power level is the Impact tab's **COST**, beside the damage it prices — a
blocked hit drains guard by it.

## Projectile moves (added 2026-09-30)

Type bar → `Projectile`. A projectile move is the same move in every other respect —
same windup/active/recovery/cooldown, same clip sync, same feint, same Test, same art binding — but when
its active window opens it **launches a volley** instead of sampling a volume on the body. There is no
separate "move type" field: the move *is* a projectile move exactly when it carries a `Projectile` block
(`MoveTypes.IsProjectile`), and switching back to Melee removes the block (the melee volume's own fields
are kept while hidden).

**It is delivery, not a second combat system.** Shots fly in `Server/Combat/HitboxEngine/ProjectileSimulator.lua`,
inside the engine's own substep loop, and every contact leaves through `HitboxEngine.OnHit` as an ordinary
`HitReport` (plus `HitReport.Projectile`). So DefenseSystem decides clean / blocked / parried / evaded /
backstab, and DamageSystem prices damage, posture, hitstun, combo and knockback, exactly as for a swing.
The differences the layers above apply, each one line:

| Where | What changes for a shot |
|---|---|
| DefenseSystem | The block arc is judged from the direction the **shot** arrived from (`SourcePosition`), not where the thrower stands. `CannotParry` meets a live window as a spent one → **blocked**, window not used up. A parried shot is answered **on the shot** (`HitboxEngine.ParryProjectile`); only `ExistingParry` also cancels + staggers the thrower. An evaded shot flies on (`PassProjectile`). Never a Trade. |
| DamageSystem | Damage and posture × the shot's `DamageScale` (reflected multipliers). Knockback pushes along the flight. No melee spacing push. |
| AttackRequestSystem | A shot's contact does not hit-confirm-cancel or keep-the-chain on the thrower's *swing*. Replicates shots on `Attack_Projectile` to the clients within `AttackConstants.Network.ProjectileRelevanceStuds` of their path (`ProjectileRelevance`). |

The Hitbox tab, for a projectile move, is seven sections, in this order (BODY, SPAWN, VOLLEY, FLIGHT,
then HOMING, COLLISION and PARRY, which start folded):

- **BODY** — what flies. *Start from* a weapon preset (Orb, Fireball, Arrow, Spear, Kunai, Shuriken,
  SwordWave, Cutter, Boulder, Log, Wall, Drill, Blade, Tide — each sets only the shape and its size), the
  shape chips (12 body shapes; pointed ones fly point first), the measurements that shape reads (the
  sphere's Radius is the spec's `Size`), and a *Scale* row (×0.5 ×0.8 ×1.25 ×2). What is drawn is exactly
  what hits.
- **VOLLEY** — Pattern (Single / Fan / Row / Column / Ring), Count, Spread angle (Fan/Ring) or Spacing
  (Row/Column).
- **FLIGHT** — Speed, Lifetime, Max range, Gravity (studs/s², negative floats), Acceleration along the heading.
- **HOMING** — Homing + strength (degrees/s of turn), max homing angle, homing range, target selection
  (`Closest to heading`, `Nearest`). Range/angle/selection also pick the target for `Fires: At target`.
  Targets are the engine's registered combatants — players, bots, dummies — never the thrower.
- **COLLISION** — On walls: `Destroy` / `Bounce off` (× Max bounces) / `Pass through`. Piercing + Max
  pierces is the separate question of **bodies**: off, the first target ends the shot; on, it passes through
  Max pierces targets and the next ends it. Each target is hit once per shot. *Can hit its thrower* (never in
  the first 0.25 s).
- **SPAWN** — Anchor and Offset (the spawn point), **Fires** (`Body facing`, `Anchor facing`, or
  `At target`), and Yaw/Pitch/Roll, which aim the volley (roll turns a fan's plane — a fan rolled 90° is
  vertical). *Place in world* places the spawn; Resize sets its size.
- **PARRY** — Parry behavior: `Parry one` (the shot parried), `Parry all` (every shot of the same volley
  still flying — every shot carries its own id and the volley's shared group id), `Cannot be parried`
  (blocked instead). When parried: `Existing parry` (shot ends, thrower staggered exactly as a parried
  swing), `Destroy`, `Reflect` (the parrier owns it; direction back at the thrower / where the parrier faces
  / mirrored off the guard; × reflected damage and speed), `Reverse direction` (the parrier owns it and it
  retraces its path).

Spread, worked: 5 shots in a 30° `Fan` fly at −15°, −7.5°, 0°, 7.5°, 15° — evenly, never random; a 360°
fan is a full ring with no doubled shot. The readout's plots draw the volley's paths with the same math
the server flies (`Shared/HitboxEngine/ProjectileMotion.lua`), as fired `Facing` with no homing.

A projectile move cannot grab (Validate: `ProjectileCannotGrab`), and a weapon stage is always melee. The
look of a shot in flight is one shared default (`FXConstants.Projectile`, drawn by `Client/FX/ProjectileFX.lua`);
its clip, trail, hit sparks and sounds come through the same paths every move's do.

## Domain expansions (realms; added 2026-09-30, own tabs 2026-10-01)

Type bar → `Domain Expansion`. A realm (an Unfurling) is a move whose accepted swing opens a temporary combat
space with its own law — the full design is `docs/design/domains.md`.

**It is still a move.** Its swing is the cast: the clip, windup, active and recovery, cooldown and locks are
the **Timing** tab's (their hints read as the cast's — the realm begins to unfurl the moment the windup ends),
the art binding and its Qi cost are **Identity**'s, its look and sound are **Presentation**'s four Realm
moments, and undo, save, Test and the readout work as for any move. What it does **not** have is a volume: a
domain move casts *volumeless* (`HitboxTypes.AttackDefinition.Volumeless`, set by
`MoveTypes.ToEngineAttackDefinition`), so the swing keeps its whole lifecycle and movement locks but samples
nothing in front of you. That is why it has no Hitbox or Impact tab. Its Realm tab's five pages are what the swing
does not say:

- **Realm** — CLOCK (unfurl / held / fold seconds), COST (Qi cost — the art binding's; bind the move to a tree
  on Identity to have one — and Qi upkeep per second), GOVERNS (how many bodies, nearest first).
- **Boundary** — SHAPE (Sphere / Cylinder / Box, radius, height), PLACEMENT (fixed / follow owner, centre
  forward, *Show on my character* to see the realm's boundary on you), CROSSING (entry and exit rules — Open /
  Barred — entry grace, exit linger, physical wall), SHOTS (may enter / may leave), COLLAPSE (owner hit while
  unfurling, owner leaves).
- **Effects** — **STRIKE PRICE** first: the realm's own way to the attack resolver. A *Strike* effect with no
  move id hits for this move's own Damage, Posture damage, Power level and Knockback — through the same
  `AttackCatalog` → `DamageSystem` path a swing takes — times the effect's **Power** (0–5, default 1). Then up
  to 6 periodic effects: *Strike* (a guaranteed, homing, parryable-if-you-say-so shot at each target),
  *Volley* (launch a projectile move at each target), *Stun*, *Drain posture*, *Pull*, *Push*, *Owner cast* —
  each with its interval, first delay, target filter and per-pulse cap. Volley and Owner cast name a **move
  id** (that move's damage, knockback and hit cues are what lands); a Strike may name one too.
- **Law** — up to 10 continuous rules on a filter: damage dealt/taken, posture taken, hitstun taken, movement
  speed, cooldowns (multipliers), seal a move / arts / projectile moves / realms, no blocking / parrying /
  evading / escape mobility, rooted.
- **Clash** — whether it interacts with other realms at all, priority, the behaviour toward a weaker realm
  (Coexist / Suppress / Erode / Dominate / Shatter), the tie-break, erode rate, contest strength, and
  per-opponent overrides keyed by the other realm's move id.

A realm move cannot grab (`DomainCannotGrab` — re-pick *Domain Expansion* in the type bar to clear an old
record's grab), and a weapon stage cannot open one. Test fires it like any move (bench bots and dummies are
valid targets).

## Preview vs. Save — the one concept to understand

- **Every edit is live within ~0.15 s.** The client debounces your edits into a `Preview`, which validates
  the draft and installs it in the live registry (or override layer). The very next swing — yours,
  anyone's — uses it. Nothing touches the DataStore.
- **Save persists.** Only Save writes the DataStore. A restart loads what was saved, not what was live.
- **Unsaved is a server fact.** Every entry carries the fingerprint of its persisted state, so `UNSAVED`
  survives closing and reopening the editor and is the same for every admin.
- **Revert** puts the live move back to its saved state (a never-saved move stops existing). **Closing**
  with unsaved work asks for a second press; the edits stay live until a restart either way.

Saving a weapon move whose values equal its built self **clears** the override instead of storing a
copy, so a later rebuild of that weapon is not pinned to today's numbers.

**Undo / redo** (Ctrl+Z, Ctrl+Y or Ctrl+Shift+Z, or the readout's pinned bar) step through your edits to the open
move — per move, 50 deep, a held stepper or a gizmo drag counting as one step. It is an edit like any
other (live after the debounce). A focused text field keeps its own undo. Revert, Reset to default,
Delete, restoring a version and a bulk scale that touches the open move all clear its undo history.

## Reading the readout

- **Plots.** TOP looks down with the attacker facing up; SIDE looks from the attacker's right, facing
  right. Every lit cell is a point the engine's own `HitboxGeometry.ContainsPoint` says is inside — the
  function the server runs on every contact — so a Cone's taper, an Arc's hub and sector and any rotation
  are drawn exactly as they hit. The volume is plotted relative to the root; a hand- or weapon-anchored
  move rides that part through the animation.
- **Drag the timeline.** The three handles on the bar's edges retime windup, active and recovery (snapped
  to 0.01 s, or to one frame with Shift); the bar shows the numbers you are setting until the server answers.
  Where the clip's strike marker sets the windup, dragging it changes only the typed number — the caption
  says so. **Press or drag the bar itself to scrub:** your character is held at that instant of the clip (a
  green playhead marks it), so a hand- or weapon-anchored hitbox drawn on you sits where it really is then.
  **Play clip** runs it forward and loops; **Release** lets your character go.
- **Effective timeline.** What `AttackCatalog` actually throws once the clip has had its say: a strike
  marker replaces the windup, the clip's length decides the recovery, weapon speed and string tempo
  rescale both. Where a number differs from what you typed, your number is in brackets. Bronze marker =
  cooldown, violet = clip end.
- **Strike marker** (white) is where the clip's `Hit` / `AttackM<n>` marker lands in swing time — where
  the hitbox opens when a marker times it. **Match timing to clip** (Timing tab) types the clip's own
  timing into Windup and Recovery, so what you typed is what the clip plays; the effective timeline does
  not move, the authored one catches up. It needs the clip's length (not a marker: with none, it keeps
  your windup and fixes recovery), and is off for a borrowed clip.
- **Frame data** (60 frames a second): startup / active / recovery, frames on hit and on block, hits to
  kill (and along a climbing string), blocks and clean hits to break a guard, damage per second. Contact
  is assumed on the first active frame (worst case) to the last ("meaty"). **There is no blockstun**, so
  on-block is always minus: it is how long you are still committed after a block — the blocker's punish.
  Every number is the server's, computed from the effective timeline and the live damage/defence
  constants, so it follows a retune.
- **Notes.** Plain-language facts from the server: a weapon-anchored Box whose size the blade replaces, a
  hitbox still open when the clip ends, a clip not read yet, a prerequisite that is not an art.

## Testing a move

**Test** (Ctrl+T) throws the open move from your own character through
`AttackRequestSystem.ThrowMove` — every gate, the engine and the damage layer, exactly as a real swing,
minus only the art machinery (no slot lookup, no Qi charge, no mastery). The footer then reports the
first hit it lands ("Landed: Clean — 12 damage, 9 guard"). **Spawn dummy** gives you a target (the Dev
Menu's own dummy), and **Show live hitbox volumes** turns on the engine's server-wide visualiser.

The **test bench** reuses the Dev Menu's own remotes: **Spawn dummy**, **Dummies hold their guard**
(the dummy guards but NEVER parries), a **sparring bot** by style and difficulty — a *ParryOnly* bot is
how you test against a parry — and **Clear all** (dummies and bots). The **hit log** lists every contact
your Test swings of this move made, newest first: outcome, damage, guard, combo stage, time after the
swing started, and the target. It clears when you open another move.

For an art, the **Hotbar slot** buttons bind it to a slot of your own bar (`ArtSystem.DevGrantAndEquip`,
the one unlock bypass) so you can fire it the way a player will. Pressing the slot it already holds
clears it.

## On your character, and Place mode

Both controls live at the end of the **Hitbox tab's PLACEMENT** section (a projectile's **SPAWN**), beside
the offset and rotation they edit. A domain expansion has *Show on my character* on its **Boundary** tab, where
it draws the realm's boundary instead.

**Show on my character** (on by default) draws the open move's volume on your own character while the
editor is open, anchored exactly where the engine anchors it (`Shared/HitboxEngine/HitboxAnchor`, the
engine's own chain) and riding the animation for a hand or weapon anchor. A weapon-anchored Box is drawn in
bronze at the blade's own size — the blade decides it. Only you see it.

**Place in world** steps the modal aside (the editor stays open and you stay frozen) and puts handles on
the volume. **1** Move (drag an arrow), **2** Rotate (drag a ring — it pivots about the volume's origin),
**3** Resize (drag a face: that face moves, the opposite one stays). The bar at the bottom picks the tool,
the snap (Free / 0.25 / 0.5 / 1 stud; any snap also snaps rotation to 15°) and shows the offset. The camera is yours
while placing: **right-drag** orbits, **middle-drag** or **W A S D / Q E** pans, the **wheel** zooms, and
**F** re-centres on the hitbox (it does not follow the volume by itself, so a drag cannot chase its own
camera). **Enter**, **Done** or **Escape** leaves Place mode and hands the camera back; the next Escape
closes the editor. Every drag is a live edit and
one undo step. While placing, 1/2/3 do not reach your hotbar.

## Bulk edit (Tools tab)

Scales timing and impact fields of **every move in the open move's group** — a weapon, *Arts*, a custom
category — optionally only one stage of a weapon's string (All / Basic / Heavy / …). Type percentages
(−75% to +300%; 0 leaves a field alone), then **Apply (live)** or **Apply & Save** (both need a second
press). It multiplies each move's CURRENT live values, so applying twice compounds; the fields clear after
each apply. The footer says how many moves changed. At most 64 moves per apply.

## Version history (Tools tab)

Every Save keeps a version (the last 10 per move, in the move DataStore). **Load history** lists them,
newest first, each with who saved it and what it changed against the version before. **Restore** (second
press) makes a version **live, not saved** — review it, then Save.

## Writing a move into the game's source (Studio only)

The DataStore is the live-server authoring path, but a move saved there lives in one universe's data, not
in git. In Studio you can write the open move into the game's **source** instead:

1. Run the helper in a terminal: `python scripts/move-writer.py` (it listens on 127.0.0.1:34880 only).
2. In Studio: **Game Settings → Security → Allow HTTP Requests** on.
3. Play, open the editor, pick the move, **Tools → SOURCE → Write to source**.

The move is written to `src/ServerScriptService/Server/Combat/AuthoredMoves/Moves/<id>.lua` (a custom
move) or `…/Overrides/<id>.lua` (a weapon move's retune); Rojo syncs it in; it ships with the build and is
reviewed in git like any other change. Its **DataStore copy is removed**, so the file is its single truth,
and the readout shows **IN SOURCE**. **Export** shows the same text to copy by hand when the helper is not
running. **Remove from source** deletes the file; the move stays live this session, unsaved. A move that is
in source cannot be deleted until it is removed from source.

**Precedence at boot**, lowest to highest: a weapon move's built constants → its **shipped** retune (the
file) → a live DataStore override. "Reset to default" returns to what **ships** (built + file). A custom
move from a file is overridden by a DataStore record with the same id — the newer live edit. The files load
from `Main.server.lua` (`Server/Combat/AuthoredMoveLibrary`), before any combat system and without needing
the editor. Outside Studio the SOURCE section is absent and its remotes refuse `NotStudio`.

## Keys

| Key | Does |
|---|---|
| `-` | open / close |
| `↑` `↓` | step through the move list (not while typing, not in Place mode) |
| `Ctrl+F` | focus the move filter |
| `Esc` | close (a second press if there is unsaved work) |
| `Ctrl+S` | save |
| `Ctrl+D` | duplicate (a copy of a weapon move keeps its clip and becomes a custom move) |
| `Ctrl+T` | test |
| `Ctrl+Z` | undo |
| `Ctrl+Y`, `Ctrl+Shift+Z` | redo |
| `1` `2` `3` (Place mode) | Move / Rotate / Resize tool |
| right-drag, middle-drag, `WASD` `Q` `E`, wheel, `F` (Place mode) | orbit, pan, pan, zoom, re-centre |
| `Enter`, `Esc` (Place mode) | leave Place mode |

## Where things live

| Piece | File |
|---|---|
| Schema, wire encoding, fingerprint, engine projection | `Shared/MoveTypes.lua` |
| Projectile schema, limits, validation / flight math | `Shared/HitboxEngine/ProjectileTypes.lua` / `ProjectileMotion.lua` |
| Projectile flight, collision, homing, parry responses | `Server/Combat/HitboxEngine/ProjectileSimulator.lua` (driven by `HitboxEngine`) |
| Projectile visuals | `Client/FX/ProjectileFX.lua`, `FXConstants.Projectile` |
| Realm schema / runtime / visuals | `Shared/Domain/`, `Server/Combat/Domain/`, `Client/FX/DomainFX.lua` (`docs/design/domains.md`) |
| Undo/redo stacks | `Shared/Authoring/DraftHistory.lua` |
| Frame data, balance numbers, clip match | `Server/Systems/Support/MoveBalance.lua` |
| Hitbox anchor chain (engine + preview) | `Shared/HitboxEngine/HitboxAnchor.lua` |
| In-world preview + Place mode gizmo | `Client/DevTools/MoveEditor/HitboxWorldPreview.lua` (`PlacementMath`, `HitboxPreviewShapes`) |
| Source generator / boot loader / helper | `Server/Systems/Support/MoveSourceWriter.lua`, `Server/Combat/AuthoredMoveLibrary.lua`, `scripts/move-writer.py` |
| Shipped moves | `Server/Combat/AuthoredMoves/{Moves,Overrides}/` |
| Editor wire contract (entries) | `Shared/Authoring/MoveEditorTypes.lua` |
| Limits, template, remote names | `Shared/Authoring/EditorConstants.lua` (`Constants.MoveEditor`) |
| Validation + custom registry | `Server/Combat/MoveRegistryManager.lua` |
| Weapon moves + override layer | `Server/Combat/DefaultMoveRegistry.lua` |
| Remotes, persistence, notes, bulk, history, source remotes | `Server/Systems/MoveEditorSystem.lua` |
| DataStore records + legacy upgrade | `Server/Systems/Support/MoveRecordCodec.lua` |
| Client driver | `Client/DevTools/MoveEditor/MoveEditorClient.lua` |
| Screen | `Client/UI/Screens/DevTools/MoveEditor/` — `init.lua` (type bar, tab availability, the Realm sub-tabs, lazy pages, help strip), `Fields.lua` (Section, Chips, Segmented, Lazy, changed-field dots, MovePicker, Suggestions, Palette), `HitboxTab` / `DomainTab` (Realm, Boundary, Effects, Law, Clash) / `TimingTab` / `ImpactTab` / `PriceFields` (cost + knockback, shared by Impact and STRIKE PRICE), `TimelineBar` (drag-to-retime, scrub) |
| Clip scrub, asset previews | `Client/DevTools/MoveEditor/ClipScrubber.lua` |

**Adding a field** means: the type in `MoveTypes.MoveDefinition`, `Clone`, `ToWire`, `Validate` (with its
bound in `Constants.MoveEditor.Limits`), the engine or damage projection if a runtime reads it, and a
field in the tab that owns it. `ToWire` is both the wire and the DataStore encoding and `Fingerprint`
digests it, so there is no second encoder to forget — the failure that silently lost Art and Grab
twice in the old editor. `MoveTypes.spec`'s round-trip test catches a field missed in any of them.
**Do not add a field no runtime reads.** That is how the last editor ended up where it did.

## What the 2026-09-29 rebuild removed, and why

Every one of these was authored, validated, persisted and shown in the old editor, and **did nothing**:

- **The twelve-shape vocabulary.** The engine runs seven; Disc, Wedge, Pyramid, Blade and Slice were
  approximated to a Cylinder or Box at swing time with a warning. The schema is now the engine's own
  (`HitboxTypes`), so nothing is approximated. `Shared/HitboxShapes.lua` is gone. *(The engine itself
  grew to fifteen real shapes on 2026-10-01 — Wedge and Pyramid among them, now exact rather than
  approximated: see "Melee moves" above.)*
- **The multi-clip animation timeline** (`Shared/AnimationTimeline.lua`) — the rebuilt client plays one
  clip per move. A move keeps a single `AnimationId`.
- **Projectile, Movement (lunge), ObjectStun (+ follow-up), Slam-on-move, ArcDegrees,
  Knockback.RagdollSeconds** — their runtimes were deleted with the old combat system. *(Projectile came
  back on 2026-09-30 as a real move type with a runtime — see "Projectile moves" above. It shares the old
  block's name only: a v1/v2 record's old Projectile is still dropped on load, never read as the new one.)*
- **The balance-graph stats panel** (`Shared/MoveStats.lua`) and its `Graph` component, the 3D
  `PreviewViewport`, the F1 shortcuts overlay, undo/redo, and the reserved `"Default"` category sentinel
  (the server now says which kind a move is). *(Undo/redo and a balance readout came back the same day,
  rebuilt — `DraftHistory` and the server-computed FRAME DATA — not the deleted versions.)*

**Existing saved content still loads.** `MoveRecordCodec` upgrades every v1/v2 record on load — the old
shapes onto the engine shapes they were already swinging as, `Depth` → `Length`, the timeline's first
enabled clip into `AnimationId` — and logs which retired fields each record carried. Nothing is rewritten
until an admin next saves it.
