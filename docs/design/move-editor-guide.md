# Move Editor — authoring guide

The Move Editor is the in-game, admin-gated tool for authoring and retuning every combat move as data.
It was **rebuilt from nothing on 2026-09-29**, schema included; the section at the end records what
went and why, so nobody rebuilds a deleted feature by accident.

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
| **Form** (tabs) | `Hitbox` · `Timing` · `Impact` · `Identity` — the inputs. Only fields that do something for this move are shown. |
| **Readout** (right rail) | The results: top and side hitbox plots, the **effective** timeline, the server's notes, and every action. |

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
- **Notes.** Plain-language facts from the server: a weapon-anchored Box whose size the blade replaces, a
  hitbox still open when the clip ends, a clip not read yet, a prerequisite that is not an art.

## Testing a move

**Test** (Ctrl+T) throws the open move from your own character through
`AttackRequestSystem.ThrowMove` — every gate, the engine and the damage layer, exactly as a real swing,
minus only the art machinery (no slot lookup, no Qi charge, no mastery). The footer then reports the
first hit it lands ("Landed: Clean — 12 damage, 9 guard"). **Spawn dummy** gives you a target (the Dev
Menu's own dummy), and **Show live hitbox volumes** turns on the engine's server-wide visualiser.

For an art, the **Hotbar slot** buttons bind it to a slot of your own bar (`ArtSystem.DevGrantAndEquip`,
the one unlock bypass) so you can fire it the way a player will. Pressing the slot it already holds
clears it.

## Keys

| Key | Does |
|---|---|
| `-` | open / close |
| `Esc` | close (a second press if there is unsaved work) |
| `Ctrl+S` | save |
| `Ctrl+D` | duplicate (a copy of a weapon move keeps its clip and becomes a custom move) |
| `Ctrl+T` | test |

## Where things live

| Piece | File |
|---|---|
| Schema, wire encoding, fingerprint, engine projection | `Shared/MoveTypes.lua` |
| Editor wire contract (entries) | `Shared/Authoring/MoveEditorTypes.lua` |
| Limits, template, remote names | `Shared/Authoring/EditorConstants.lua` (`Constants.MoveEditor`) |
| Validation + custom registry | `Server/Combat/MoveRegistryManager.lua` |
| Weapon moves + override layer | `Server/Combat/DefaultMoveRegistry.lua` |
| Remotes, persistence, notes | `Server/Systems/MoveEditorSystem.lua` |
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
  Knockback.RagdollSeconds** — their runtimes were deleted with the old combat system.
- **The balance-graph stats panel** (`Shared/MoveStats.lua`) and its `Graph` component, the 3D
  `PreviewViewport`, the F1 shortcuts overlay, undo/redo, and the reserved `"Default"` category sentinel
  (the server now says which kind a move is).

**Existing saved content still loads.** `MoveRecordCodec` upgrades every v1/v2 record on load — the old
shapes onto the engine shapes they were already swinging as, `Depth` → `Length`, the timeline's first
enabled clip into `AnimationId` — and logs which retired fields each record carried. Nothing is rewritten
until an admin next saves it.
