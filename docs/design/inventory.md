# Inventory — blueprint and plan

Status: phase 1 built (2026-10-08), not yet exercised in Studio. Phases 2+ are the plan, not code.
Owner doc for: `Server/Systems/InventorySystem.lua`, `Shared/Inventory/*`, `Client/Inventory/InventoryClient.lua`,
`UI/Screens/Inventory/`.

## 1. What was there (audit, 2026-10-08)

Two unrelated "inventories" existed, and nothing else held items:

| System | What it held | Where it lived | Problem |
| --- | --- | --- | --- |
| `Combat/Weapon/WeaponInventorySystem` | weapons picked up (`Owned`/`Order`), selected, drawn | a server `records[player]` table | **session-only** (lost on rejoin, by its own header); no UI beyond the 1-line armament island |
| `Types.PlayerProfile.blimpFuel` + `ResourceGatheringSystem` + `BlimpSystem.depositFuel/unloadFuel` | carried Coal / Water | two numbers on the profile, capped by `BlimpConstants.Carry` | persisted, but a special case: every new carried resource would need a new profile field, a new migration, a new remote, a new HUD readout |

Both are server-authoritative already (good). Neither had a shared model, a catalog, sections, capacity, or a screen.

## 2. Decisions

1. **One owner.** `InventorySystem` is the only writer of a player's items. Weapons and carried resources become *entries in it*, not parallel stores. Everything that gives or takes an item calls its API; nothing else touches `profile.inventory`.
2. **Server-authoritative, intent-only client.** The client never sends a count or a result. It sends an *intent* (`Discard`, itemId, count) and the server re-validates item, ownership, amount and rate. State flows down as full snapshots (small, idempotent: a client that missed one is corrected by the next).
3. **Stacks keyed by item id, not a slot grid.** The profile stores `{ Items = { [itemId] = count }, Order = { itemId } }`. A "slot" is derived: `ceil(count / MaxStack)` per item, summed per section against that section's slot limit. No x/y positions to corrupt, migrate or exploit, and it matches the UI rule *"avoid cluttered MMO inventory grids"* (`ui-ux-philosophy.md`). Per-instance items (rolled stats, durability) are phase 2 and get their own `Instances` table; stacks stay the cheap common case.
4. **Catalog is data, in `Shared`.** `ItemCatalog` defines every item (id, section, rarity, stack size, carry cap, discardable). Adding an item is one entry. Weapons are *derived*, not authored twice: item id `Weapon/<WeaponId>`, so adding a weapon is still only a Studio action (`WeaponRoster`'s existing contract).
5. **Fists are not items.** They are always in hand (design decision 2026-10-06) and are never stored, picked up or dropped.
6. **Orphans are kept, not deleted.** A saved item whose catalog entry or weapon model has since been removed stays in the profile but is hidden from the roster/UI/limits. Deleting player data because content was renamed is not recoverable; hiding is.
7. **Capacity = per-section slot limits** (no weight yet). Per-item `MaxCarry` is a separate hard cap (this is what `BlimpConstants.Carry` is: coal/water read their cap from there, so tank size and pocket size stay tuned together).
8. **Partial adds, never silent loss.** `Add` returns how many actually fit. Callers decide what to do with the remainder (a gather is capped; a future drop leaves the rest in the world).

## 3. Sections

Structure the player sees (tab strip of the inventory screen). A section with `HideWhenEmpty` has no tab until it holds something, so the screen never shows dead tabs.

| Section | Holds | Slots | Always shown |
| --- | --- | --- | --- |
| Armaments | weapons | 24 | yes |
| Resources | gathered resources (Coal, Water, later ore/herbs) | 12 | yes |
| Materials | crafting inputs | 40 | no |
| Consumables | pills, elixirs, talismans | 20 | no |
| Relics | key items, quest items, bloodline artefacts | 12 | no |

Rarity uses the cultivation grading, expressed by colour **and** a text label (colour is never the only signal): Mortal, Spirit, Earth, Heaven, Immortal.

## 4. Data model

```
profile.inventory = {
  Items = { ["Coal"] = 120, ["Weapon/Cutlass"] = 1 },   -- count per item id
  Order = { "Weapon/Cutlass", "Coal" },                  -- first-acquired order (weapon cycle order)
}
```

Schema v10 → v11. `Migrations[10]` moves `blimpFuel.Coal/Water` into `Items.Coal/Water` and removes `blimpFuel`. Decode is defensive (counts floored to positive integers, junk keys dropped, order rebuilt).

Wire (server → owning client, `Inventory_Snapshot`):
```
{ Revision, Sections = { { Id, Used, Limit, Entries = { { ItemId, Count } } } } }
```
Client resolves display data from the shared catalog; `Used`/`Limit` come from the server so the client never recomputes capacity with a different resolver.

Intent (client → server, `Inventory_Action`, RemoteFunction): `("Discard", itemId, count) -> { Success, Reason?, Removed? }` and `("Sync") -> { Success }`, which only asks the server to push the snapshot again — a client that booted after the profile loaded missed the first push. Both are rate-limited (6/s).

## 5. Server API (`InventorySystem`)

`Add(player, itemId, n) -> added, reason?` · `Remove(player, itemId, n) -> removed` · `Count` · `RoomFor` · `OwnedIds(player, sectionId?)` · `IsLoaded`
Events: `OnChanged(player, itemId, count)` · `OnLoaded(player)`.
All writes go through `PlayerDataSystem.Transform`, so persistence, dirty flags, autosave, the session lock and write-generation backstop are inherited, not re-implemented.

## 6. Integrations moved onto it (phase 1)

- `WeaponInventorySystem`: ownership is now `Count(Weapon/<id>) > 0`; it keeps only *selected* and *drawn* (genuinely per-session combat state). Pickup → `InventorySystem.Add`. Weapons now **persist**; selection restores to the first owned weapon on load.
- `ResourceGatheringSystem`: a gather is `RoomFor` + `Add`; HUD readout (`CarriedFuelUpdated`) is driven off `OnChanged`, so discarding from the inventory also updates the corner readout.
- `BlimpSystem.depositFuel/unloadFuel`: read/debit/credit the inventory instead of `profile.blimpFuel`.
- `DevMenu` "Fill carried fuel": fills via `Add`.

## 7. UI

`UI/Screens/Inventory` — a `ScreenFrame` modal on **J** (`InventoryToggle`, rebindable in Settings; Escape closes). Not I: `SettingsToggle`'s comment in `KeybindConstants` records the I/O/P cluster not reaching `UserInputService` on one dev machine, and I/O are the default camera zoom keys. Tab strip = sections. Body = item list on the left (cards: silhouette tile, name, rarity chip, count, per-item cap meter), detail pane on the right (description, rarity, carry cap, actions). Footer status line answers actions. Not built yet: HUD key-legend entry for the inventory, gamepad open chord, authored item art (tiles show the item's initial). Section header shows `used / limit` slots as a `SegmentMeter`. Style per `ui-ux-philosophy.md`: sharp panel, hairline borders, violet = live/selected, bronze = committed; rarity by colour + label. Gamepad: traversable via `Selection`; opening on gamepad is a follow-up (needs a chord).

## 8. Phases

| Phase | Scope | Status |
| --- | --- | --- |
| 1 | Model, catalog, `InventorySystem`, persistence + migration, weapons & carried resources moved onto it, sectioned screen with Discard | **built** |
| 2 | Equipment slots (gear worn by the character; stat deltas through `CombatPower`-style composition, not a new combat layer), per-instance items (`Instances`, uid, durability, rolled affixes) | planned |
| 3 | World drops & pickup (`ItemDropSystem`: dropped item = server-owned world entity with owner-lock timer, despawn, range re-check like the weapon prompt), death-drop policy (decide with combat/economy: fight-to-grow argues against full loot) | planned |
| 4 | Containers & stash (shared faction storage, bank), expansion by tier | planned |
| 5 | Player-to-player trade (two-phase commit: both sides lock, server swaps atomically in one `Transform` pair, abort on any failure), then market | planned |
| 6 | Search / sort / filter / compare in the UI; favourites; new-item markers | planned |

## 9. Risks and open questions

- Death policy decides whether items can be lost on death. Not decided; phase 3 blocker, not phase 1.
- Slot limits (24/12/40/20/12) are placeholders to tune in playtest, not derived numbers.
- Orphaned items accumulate silently; add an admin report before the first content removal.
- Two simultaneous servers: already covered by PlayerData's session lock; trade (phase 5) must not bypass it.
- Persistence cost: the whole inventory rides the existing profile save (dirty-flag, 180s autosave). If inventories grow past a few hundred entries, split into its own key.
