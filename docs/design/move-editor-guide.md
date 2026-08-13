# Move Creation System — authoring guide

The Move Editor is an in-game, admin-gated tool for authoring and retuning combat moves without a
Studio round trip. This document covers what it does, the one concept that most often trips people
up (draft vs. save), and how to extend it.

**Field-by-field help text is not duplicated here.** Every field's unit and explanation lives in
`src/StarterPlayer/StarterPlayerScripts/Client/UI/Screens/MoveEditor/Copy.lua`, which is what the UI
actually renders. If this document and that module ever disagree, **`Copy.lua` is right and this
document is stale.**

---

## Opening it

Press `-` (`Constants.Keybinds.Defaults.OpenMoveEditor`). Nothing happens for a non-admin: the client
module never even starts unless the server authorises it, and `MoveEditorSystem` re-checks
`AdminConfig.AuthorizedUserIds` on every single remote regardless of what the client believes.

**Opening the editor freezes your character.** `SetEditorOpen` routes through
`AdminActionSystem.SetFrozen`, so you cannot walk or attack while editing. Closing unfreezes you.
This is deliberate — editing a move's numbers while your character is mid-combo is how you lose
track of which state you're in.

## Custom moves vs. Default moves

The move list has two tabs, and they hold genuinely different things.

| | **Custom** | **Default** |
|---|---|---|
| Backed by | `MoveRegistryManager`, DataStore | a live `Constants.lua` table |
| Created by | you, in this editor | hand-authored in code |
| MoveId | generated slug + suffix | synthetic, e.g. `default:Primary:Basic:1` |
| Deletable | yes | **no** — only reset |
| Test on Dummy | yes | no (just attack in-game) |
| Duplicate | yes | no |
| Movement / Knockback / Projectile / Object Stun | yes | **inert** — the nav items are hidden |
| Animation | authored clip timeline | inferred from the attack's name |

`Category == "Default"` is a **reserved sentinel**, not an ordinary tag. Typing it into a custom
move's Category is rejected server-side with `ReservedCategory`, and the editor blocks it before the
request is even sent. A custom move wearing that Category would be filtered into the Default tab,
have its optional sections hidden and its Delete action removed, and route its saves to the wrong
handler — i.e. become unreachable and undeletable. That is the entire reason the gate exists.

Editing a Default move changes the *live* Constants table by reference, so it takes effect for
everyone on the server immediately. Save persists it as a DataStore override that re-applies on every
boot; **Reset to Default** both reverts the live values and deletes that override.

## Draft vs. Save — read this one

This is the single most misunderstood thing about the editor.

- Every edit you make fires `UpdateDraft` (debounced ~0.15s). That mutates the server's **in-memory**
  registry. The move is immediately live: Test on Dummy sees your change, and so does a hotbar-bound
  move fired in real combat.
- **Only `Save` writes the DataStore.** Nothing is persisted until you press it.

So a move can be fully working in this session and still be *completely gone* after a server restart.
The **UNSAVED** chip in the toolbar is the only thing that tells you so — it appears the moment the
draft differs from what was last saved or loaded, and clears on Save. Trying to close with unsaved
changes refuses once and asks you to press again.

**Honest limitation.** "Unsaved" is scoped to *this editing session*. `GetMove` returns the live
in-memory registry, which `UpdateDraft` has already mutated — so if you edit a move, navigate away
without saving, then re-select it later in the same session, it reads as clean even though the
DataStore still holds the older values. Detecting that properly needs the server to report
persisted-vs-live divergence, which is a real feature rather than a polish item. Until then: if the
chip has ever appeared for a move, save it.

## Testing a move

**Test on Dummy** spawns (or reuses) a preview dummy and throws the move at it. Results stream back
over the existing combat feedback remotes and land in two places: the one-line readout in the
toolbar, and the Stats section's measured curve.

The collection window stays open for the move's own full duration plus 4 seconds. That trailing
margin is generous on purpose — an Object Stun follow-up schedules itself well after the parent
move's recovery ends, and a sample that arrives after the window closes is silently lost, which is a
much worse failure than a window that stayed open a second too long.

A multi-hit move reports **N hits and a running total**, not just the last hit. The Stats section
plots the projected damage curve (computed from your fields) against the measured one (what actually
landed) on shared axes.

## The preview

The right column is a live 3D preview: an R15 dummy with the real hitbox drawn at its real size and
offset. Click-drag to orbit, scroll to zoom. The phase buttons step through Windup/Active/Recovery
manually; Play loops the whole move, including lunge translation and projectile flight, using the
same formulas the server does.

## Hotbar binding

The five slot buttons in the toolbar bind the selected move to a HUD hotbar slot. Clicking the slot a
move already occupies unbinds it. Custom moves only — a Default move's MoveId is not in the custom
registry, so binding one would produce a permanently dead slot.

Bindings are **client-side and session-only**; they do not survive a rejoin. Firing a bound move
still round-trips through the server, which re-validates both you and the move.

## Keyboard shortcuts

| Key | Action |
|---|---|
| `-` | Open / close the editor |
| `Esc` | Close (asks twice if there are unsaved changes) |
| `Ctrl`/`Cmd` + `S` | Save |
| `Ctrl`/`Cmd` + `D` | Duplicate the selected move |

Two honest caveats:

- **`Ctrl+S` does nothing while a text field has focus.** Roblox marks text input as game-processed
  and the handler ignores those events. This is the safe failure — it can't commit a half-typed name
  — but it will surprise you. Click out of the field first.
- **`Esc` can be swallowed by the Roblox menu**, which claims it under some conditions. The `X`
  button is the guaranteed close path.

## Adding a new field to the editor

The checklist that makes this document worth keeping. A new authored field has to be threaded
through all of these, and skipping any one of them fails quietly rather than loudly:

1. **`Shared/MoveTypes.lua`** — add it to `MoveDefinition`.
2. **`Shared/MoveTypes.lua`** — add it to `Clone` (it's an explicit field list, not a generic deep
   copy) and to `Fingerprint` (or dirty-tracking won't notice it changing).
3. **`Server/Combat/MoveRegistryManager.lua`** — validate it in `Validate`. Structural errors reject;
   in-range numeric errors clamp.
4. **`MoveTypes.ToHitboxAttackDefinition`** — project it, if combat needs to see it.
5. **`Client/MoveEditor/MoveEditorClient.lua`** — `encodeDraftForWire` and `defaultDraft`.
6. **`Server/Systems/MoveEditorSystem.lua`** — `encodeMoveRecord` / `candidateFromStoredRecord`, or
   it will not survive a restart.
7. **`Screens/MoveEditor/PropertyEditor.lua`** — the actual control.
8. **`Screens/MoveEditor/Copy.lua`** — its unit and hint. `Copy.Field` asserts on an unknown key, so
   a missing entry fails loudly the first time that section opens.
9. **`src/Tests/Combat/MoveTypes.spec.lua`** — a `Fingerprint` sensitivity case and a `Clone`
   independence case if the field is a table.

## Where things live

| Concern | File |
|---|---|
| Schema, `Clone`, `Fingerprint`, `DefaultCategory` | `src/ReplicatedStorage/Shared/MoveTypes.lua` |
| Validation, clamping, the reserved-category gate | `src/ServerScriptService/Server/Combat/MoveRegistryManager.lua` |
| Auth, remotes, DataStore | `src/ServerScriptService/Server/Systems/MoveEditorSystem.lua` |
| Default-move projection | `src/ServerScriptService/Server/Combat/DefaultMoveRegistry.lua` |
| Screen root, dirty tracking | `src/StarterPlayer/.../UI/Screens/MoveEditor/init.lua` |
| The authoring form | `.../MoveEditor/PropertyEditor.lua` |
| All explanatory text | `.../MoveEditor/Copy.lua` |
| Remotes, shortcuts, duplicate, guarded close | `src/StarterPlayer/.../Client/MoveEditor/MoveEditorClient.lua` |

Every one of those files carries a long header explaining its own design decisions. Those headers are
the detailed reference; this document is the map.
