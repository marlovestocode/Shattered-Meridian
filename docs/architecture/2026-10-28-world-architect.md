# World Architect (2026-10-28)

An admin-only, in-game world construction tool. Opened with `]` (`OpenWorldArchitect`) by a whitelisted admin.

## What existed before

- **No world-building or world-persistence code at all.** The map is authored in Studio and lives in the place file;
  `default.project.json` maps only `Workspace.Onboarding` (spawns). `WorldSystem` is an empty stub. Nothing serialises
  or reconstructs Workspace content.
- The admin tool pattern is settled: a `Server/Systems/<X>System` declaring admin `Endpoint`s (AdminGate auth + its
  own RateLimiter), a `Client/DevTools/<X>/<X>Client` driving a `Lazy` screen under `UI/Screens/DevTools/<X>`, a
  keybind in `KeybindConstants`, DataStore through `DataStoreRetry.Scoped`, schema-versioned records, index documents
  through `AuthoredContentStore`. KitEditor is the closest small example.
- The Move Editor's Place mode already solved "free the mouse and fly a camera while editing in the world"
  (`DevTools/MoveEditor/PlacementCamera.lua`). World Architect reuses it (Start gained an options table for the
  owner name and the zoom limit) instead of writing a second editor camera.

## Shape

| Layer | Module | Owns |
|---|---|---|
| Shared, pure | `Shared/WorldArchitect/ArchitectConstants` | remote names, every limit, roles, shapes, materials |
| | `ArchitectRecord` | the node record (Part / Group), its Schema decode, role defaults, record <-> CFrame |
| | `ArchitectTransform` | snapping, bounds, pivots, translate/rotate/scale of a set, align, distribute, mirror, array, surface placement |
| | `ArchitectTemplates` + `StarterTemplates` | template validation / instantiate / capture; the built-in starter library (primitives only, no asset ids) |
| | `ArchitectGenerator` | deterministic seeded generators (Ruins, Outpost, Pathway, Grove) with spacing, exclusion, footprint rejection |
| | `ArchitectOptimizer` | measured analysis + a role-aware, reversible change plan (Safe / Destructive) |
| | `ArchitectHistory` | bounded per-admin transaction stacks with per-node revision conflict checks |
| | `ArchitectCodec` | compact DataStore encoding, chunking, schema migration |
| Server | `Server/WorldArchitect/WorldState` | the authoritative record store: validation, protected zones, revisions, transactions (no Instances) |
| | `WorldMaterializer` | records -> Instances under `Workspace.ArchitectWorld`, diff-applied |
| | `WorldPersistence` | slots (Live + drafts), generation-based atomic chunked saves, snapshots, restore; saved templates |
| | `TerrainBrush` | bounded terrain strokes with voxel snapshots for undo; stroke log persisted and replayed |
| | `ProtectedZones` | spawn pads and other areas nothing may be built into |
| | `Server/Systems/WorldArchitectSystem` | endpoints, per-admin history and subscription, delta pushes, boot load of the Live slot |
| Client | `Client/DevTools/WorldArchitect/WorldArchitectClient` | key, authorization, mirror of server records, request dispatch |
| | `EditorViewport` | picking, selection boxes, gizmos, placement / generation / terrain previews, the editor's input sink |
| | `UI/Screens/DevTools/WorldArchitect/*` | docked console: toolbar, assets + scene (left), inspector / build / world / optimize / terrain (right), status bar |

## Decisions

1. **Protected by construction.** The server only ever touches Instances it created under `Workspace.ArchitectWorld`,
   addressed by server-issued string ids. A client cannot name any other Instance, so the Studio map, spawns and
   systems are unreachable. Spawn pads are additionally exclusion zones nothing may be placed into.
2. **Records, not Instances, are the truth.** Every edit is validated against `ArchitectRecord`'s Schema shapes and
   `ArchitectConstants` limits, applied to `WorldState`, then materialised. Persistence stores records.
3. **Revision checks for concurrent admins.** Each node carries `Rev`. An update or delete names the Rev it was made
   against; a stale one is refused (`StaleNode`). Undo checks the touched nodes still carry the Revs its transaction
   left; if another admin changed them since, the undo is refused (`UndoConflict`) and dropped rather than overwriting.
4. **Generation is recomputed on commit.** The preview and the commit run the same deterministic function on the same
   config server-side; the client's ghost layout is never trusted.
5. **Three tiers of state.** Working (this server's Workspace, immediate), Draft slots (named, saved), Live slot
   (loaded at every boot). Each slot keeps its last generations as snapshots; a save writes a new generation's chunks
   and then moves the head pointer with `UpdateAsync`, so a partial failure leaves the previous save intact.
6. **The optimizer only proposes reversible record edits** and applies them as one ordinary undoable transaction.
   It never changes collision on Structure / Walkable / Barrier roles, never merges parts, never touches collision
   groups. Duplicate deletion is the only Destructive change and is never in "Apply safe".
7. **Hide is editor-local** (LocalTransparencyModifier on the admin's client): it never changes what players see.
8. **Undo chains rebase.** An undo or redo re-stamps the nodes it touches with a new revision while restoring exactly
   the state the next entry down expects, so `ArchitectHistory.Rebase` moves the nearest entry's expected revision to
   the new one. Another admin's edit still fails the check (`UndoConflict`). Without it, create -> edit -> undo -> undo
   would refuse its own second step.
9. **Server-owned physics.** An unanchored built part keeps the server as network owner, so no client can move it.
10. **Bounded on every axis.** Requests <= 600 nodes, server expansions <= 1500, world <= 6000, templates <= 400 nodes /
    400 studs, history <= 64 steps / 24k node copies per admin, delta pushes <= 120 records each, terrain strokes
    <= 24 studs radius and 256 in the log (each keeps its voxel snapshot, ~25 MB at most), saves <= 12 chunks of 1 MB.

## Shared pieces this added or extended

- `UI/Shell/ModalCount.lua` -- the open-modal count and UiModalOpen publisher lifted out of `Components/ModalScreen`
  (which now calls `ModalCount.Track`), so a docked full-bleed surface can gate gameplay input through the same counter.
- `DevTools/MoveEditor/PlacementCamera.Start(focusOf, { Owner, MaxDistance })` -- shared editor orbit camera; returns
  `Focus()` / `FocusOn(point)` too.
- `Tests/TestHelpers/FakeDataStore.lua` -- in-memory Get/Set/Update/RemoveAsync with scripted failures, plus `NoRetry`.
- `ProtectedZones.Tag` = `ArchitectProtected` -- tag any BasePart or Model in Studio to fence it off from building.

## Not done / limits (stated, not hidden)

- Terrain edits are persisted as a stroke log replayed on load; a re-published place whose base terrain changed will
  replay the strokes onto the new terrain.
- Favourites and recents are per session (client memory).
- The gizmo is mouse + keyboard only, like the Move Editor's Place mode.
- Mirror of wedge shapes reflects position and rotation; a wedge's slope does not invert (no mirrored part type).
- A Load replaces the working world after its fetch and autosave yield; an edit another admin lands inside that
  window is replaced too (the Reset push tells every open editor).
- Nothing in this pass was playtested in Studio; see the session report for what the suite covers.

## The sect-era library (2026-10-28, second pass)

`Shared/WorldArchitect/Library/` replaced the first starter kit. `ArchitectureKit` is the grammar every built-in uses:
the named palette (`Kit.Tones`, the old ten plus Plaster, RoofTile, Lacquer, Ember), three faction styles, the 4-stud
module / 16-stud bay, one roof language (slopes, hip skirts, ridge beasts, fascia, flying corners, tile ribs), eave
rings, wall panels, bracket-set columns, and `Kit.Ruin` -- a seeded pass that strips roofs and ornament, snaps posts
and walls, and adds rubble, moss and Meridian seams while leaving the Base layer (the footprint) untouched.
`Structures`, `KitPieces`, `Landmarks` and `Dressing` declare families; `StarterTemplates` expands each faction family
into Celestial / Demonic / Unbound and the ruin of each (ids `<family>.<faction>[.ruin]`).

Templates now carry Type (Kit / Assembly / Landmark / Dressing), Faction, Region and Variant (Intact / Ruined);
stored templates without them decode with defaults. Two composing generators, Sect Compound and Ruined Quarter, lay a
whole walled compound out of kit pieces and assemblies. `Tests/WorldArchitect/ArchitectureLibrary.spec.lua` holds the
cohesion rules: named tones only, kit pieces tile on the grid, ruins keep their footprint, per-type part budgets,
glows are Decor, floors and steps are Walkable.
