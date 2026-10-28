# Content layers (W16, 2026-10-27)

Read from source before `Server/Data/ContentRegistry.lua` was written. "Wins" means: when two layers hold the same id, a read
gets this one.

| Kind | Layers, highest first | Storage | Where an edit lands | Bound through ContentRegistry? |
|---|---|---|---|---|
| Move | **Custom** (`MoveRegistryManager`) > **Default** (`DefaultMoveRegistry`) | Custom: DataStore records (`MoveEditorSystem`), plus files in `Server/Combat/AuthoredMoves` loaded by `AuthoredMoveLibrary` (a DataStore record with the same id wins). Default: the built weapon roster, with shipped overrides and DataStore overrides folded in by `DefaultMoveRegistry.Get` itself | Move Editor: custom move -> `MoveRegistryManager.Upsert`; Default move -> an override record | **Yes**, `Server/Combat/MoveContent.lua` |
| Race trait | one table (`RaceManager`) | DataStore records (`KitEditorSystem`) upserted over an empty table | `RaceManager.Upsert` | No: one layer, nothing to resolve |
| Bloodline | one table (`BloodlineManager`) | canon roster seeded by `DefaultBloodlineRegistry`, then DataStore records upserted IN PLACE over it | `BloodlineManager.Upsert` | No: one layer. Note: deleting an authored bloodline that shadowed a canon one removes the canon one too until restart -- the single table cannot fall back. Escalation C1 below |
| Emote, item | static catalogs (`EmoteCatalog`, `ItemCatalog`) | source | source | No: one layer, no authoring |

**Consumers moved to `MoveContent`:** `AttackCatalog.resolveMove`, `MovePresentationSystem` (effective presentation, rebuild,
change subscription), `MoveEditorSystem` (`sourceOf`, the Open listing, bulk targets), `AttackRequestSystem`'s preload list.
Proven by `Tests/Data/ContentRegistry.spec.lua` (old `Get or Get` vs `MoveContent.Resolve` over every live id).

**Readers that deliberately want one layer** keep asking it: arts and realms are custom moves only (`ArtTreeManager`,
`DomainSystem`), and the editor's saved/built state is per layer (`DefaultMoveRegistry.GetBuilt`, `AuthoredMoveLibrary`).

**Order note.** The Move Editor's Open listing and bulk targets keep their old order (Default entries first, then custom). The
attack preload list now lists custom moves first; it only feeds `ContentProvider` preloading, where order has no effect.

**Escalation C1.** Give bloodlines a real Default layer (canon roster in `DefaultBloodlineRegistry`, authored records above it) so
deleting an authored override restores the canon entry. Option A: bind bloodlines through ContentRegistry with two layers; effort M,
touches KitEditorSystem's delete path. Option B: keep the single table (a restart restores it). Not changed.
