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
| **Moves** (left rail) | Every move the game knows, grouped: Arts, your categories, Custom, one group per roster weapon (collapsed), Standalone. Filter by name, id or group. A bronze chip says `NEW`, `UNSAVED` or `TUNED`. |
| **Form** (tabs) | `Hitbox` · `Timing` · `Impact` · `Identity` — the inputs. Only fields that do something for this move are shown. `Tools` holds what acts on more than one move's inputs: bulk edit, version history, and (Studio) source. |
| **Readout** (right rail) | The results: top and side hitbox plots, the **effective** timeline, frame data, the server's notes, every action, the test bench and the hit log. |

The rails are pinned so a result is never a tab switch away from the input that caused it.

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

## Projectile moves (added 2026-09-30)

Hitbox tab → **Move type** → `Projectile`. A projectile move is the same move in every other respect —
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

The Hitbox tab, for a projectile move, shows four folding groups (click a heading to Hide/Show):

- **PROJECTILE** — Spread pattern, Count, Spread angle (Fan/Ring) or Spacing (Row/Column), Speed, Lifetime,
  Max range, Size (the *radius* of the flying sphere — what is drawn is exactly what hits).
- **SPAWN** — Anchor and Offset (the spawn point), **Fires** (`Facing` the body, where the `Anchor` points,
  or `At the target`), and Yaw/Pitch/Roll, which aim the volley (roll turns a fan's plane — a fan rolled 90°
  is vertical). *Place in world* places the spawn sphere; Resize sets Size.
- **MOVEMENT** — Gravity (studs/s², negative floats), Acceleration along the heading, Homing + strength
  (degrees/s of turn), max homing angle, homing range, target selection (`Aim` = smallest angle off the
  heading, `Nearest`). Range/angle/selection also pick the target for `Fires: At the target`. Targets are
  the engine's registered combatants — players, bots, dummies — never the thrower.
- **COLLISION** — On walls: `Destroy` / `Bounce off` (× Max bounces) / `Pass through`. Piercing + Max
  pierces is the separate question of **bodies**: off, the first target ends the shot; on, it passes through
  Max pierces targets and the next ends it. Each target is hit once per shot. *Can hit its thrower* (never in
  the first 0.25 s).
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

## Realms (added 2026-09-30)

**Domain** tab → *This move opens a realm*. A realm (an Unfurling) is a move whose accepted swing opens a
temporary combat space with its own law — the full design is `docs/design/domains.md`. The swing is the
activation: its clip, windup, cooldown, art binding (Qi cost) and Presentation are authored where they
always are, and the Domain tab is only what the swing does not say, in five groups:

- **BASIC** — name/description (the move's own), activation / duration / fold seconds, cooldown (the move's),
  Qi cost (the art binding's — bind it to a tree on Identity to have one), Qi upkeep per second, max targets.
- **BOUNDARY** — shape, radius, height, anchor (fixed / follow owner), centre offset, entry and exit rules
  (Open / Barred), entry grace, exit linger, physical wall, whether shots may enter / leave, and the two
  owner-side collapse conditions.
- **EFFECTS** — up to 6 periodic effects: *Strike* (deliver a move to each target as a guaranteed, homing,
  parryable-if-you-say-so shot), *Volley* (launch a projectile move at each target), *Stun*, *Drain posture*,
  *Pull*, *Push*, *Owner casts a move* — each with its interval, first delay, target filter and per-pulse cap.
  Strike/Volley/Owner cast name a **move id**: that move's damage, knockback and hit cues are what lands.
- **COMBAT** — up to 10 continuous rules on a filter: damage dealt/taken, posture taken, hitstun taken,
  movement speed, cooldowns (multipliers), seal a move / arts / projectile moves / realms, no blocking /
  parrying / evading / escape mobility, rooted.
- **CLASH** — priority, the default behaviour toward a weaker realm (Coexist / Suppress / Erode / Dominate /
  Shatter), the tie-break, erode rate, contest strength, whether it interacts at all, and per-opponent
  overrides keyed by the other realm's move id.

Its look and sound are the Presentation tab's four **Realm** moments (unfurls / established / effect fires /
folds); `DomainActive`'s core colour tints the realm and its glow draws the edge. A realm move cannot grab
(`DomainCannotGrab`), and a weapon stage cannot open one. Test fires it like any move (bench bots and dummies
are valid targets).

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

**Undo / redo** (Ctrl+Z, Ctrl+Y or Ctrl+Shift+Z, or the ACTIONS row) step through your edits to the open
move — per move, 50 deep, a held stepper or a gizmo drag counting as one step. It is an edit like any
other (live after the debounce). A focused text field keeps its own undo. Revert, Reset to default,
Delete, restoring a version and a bulk scale that touches the open move all clear its undo history.

## Reading the readout

- **Plots.** TOP looks down with the attacker facing up; SIDE looks from the attacker's right, facing
  right. Every lit cell is a point the engine's own `HitboxGeometry.ContainsPoint` says is inside — the
  function the server runs on every contact — so a Cone's taper, an Arc's hub and sector and any rotation
  are drawn exactly as they hit. The volume is plotted relative to the root; a hand- or weapon-anchored
  move rides that part through the animation.
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

Both controls live at the end of the **Hitbox tab's PLACEMENT** section, beside the offset and rotation
they edit.

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
| Screen | `Client/UI/Screens/DevTools/MoveEditor/` |

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
  (`HitboxTypes`), so nothing is approximated. `Shared/HitboxShapes.lua` is gone.
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
