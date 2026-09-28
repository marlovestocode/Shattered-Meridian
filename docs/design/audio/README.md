# Landing impact audio (source files)

`hard_landing_01.wav` and `hard_landing_02.wav` are the source clips for the parkour landing
impact sounds — Roblox has no runtime support for local audio files, so each needs a one-time
upload before it is live in-game, the same "source asset, needs a human export step" pattern
`docs/design/icons/`'s SVGs follow for their own PNG export.

- `hard_landing_01.wav` → the **hard** landing (`ParkourConstants.Fall.HardLandingSound`)
- `hard_landing_02.wav` → the **soft** landing (`ParkourConstants.Fall.SoftLandingSound`, also
  reused for the Medium tier — see that constant's own comment)

## To go live

1. Upload each file to Roblox: Studio's Toolbox → Inventory → Audio → Upload (or the creator
   dashboard), under whichever account/group owns this game's assets.
2. Roblox hands back an asset id. Paste it into
   [`src/ReplicatedStorage/Shared/Parkour/ParkourConstants.lua`](../../../src/ReplicatedStorage/Shared/Parkour/ParkourConstants.lua)
   as `rbxassetid://<id>` on the matching `SoundId` field (three fields — `SoftLandingSound`,
   `MediumLandingSound`, `HardLandingSound` — the first two both point at `hard_landing_02.wav`'s id).
   An un-uploaded clip stays `""` (plays as silence); never leave the bare `"rbxassetid://"` prefix,
   which fails to load and fails `Tests/Loading/AssetPreloader.spec.lua`.

**Status:** `hard_landing_01.wav` is uploaded and live. `hard_landing_02.wav` (soft/medium) is pending.
3. No other code changes needed — `Client/FX/ParkourAudio.lua` registers and plays them, and
   `Client/Loading/AssetPreloader.lua` already sweeps every `SoundManager`-registered clip at boot.
