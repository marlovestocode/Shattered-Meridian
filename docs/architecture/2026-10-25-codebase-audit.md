# Codebase audit: bugs, wiring and design (2026-10-25)

Scope: the whole `src/` tree (769 files, ~226k lines including specs), with extra depth on the last five
commits (`0f83e22`..`5b11cd7`) and on the server Systems the combat audits haven't covered. Every finding
below was checked against source on this date. Nothing here restates an open item from
`2026-10-08-combat-state-audit.md` without re-checking it first.

## Method

- Gates: `selene src/` gives 0 errors and 2 warnings (`UDim2.fromScale`, `UI/Screens/Inventory/init.lua:521,528`).
  `scripts/check-logger-scopes.py` passes (177 scopes), and so does `scripts/check-live-project.py`.
- Mechanical scans: orphan modules, measured by inbound requires from outside each module's own file. Remote
  handlers with no rate limit. Bare `RootControlLocked` writes, raw `GetNetworkPing`, `print`/`warn`.
  `table.remove` while iterating forward, and yields inside frame callbacks. `[Player]`/`[Model]` tables with no
  cleanup. Attributes that are written but never read, or read but never written. Top-level folders missing
  from `test.project.json`.
- Most of these came back **clean**: every public remote has a limiter or `AdminGate`, there are no stray logs
  and no yields in frame callbacks. The real bugs are in what the code means, not in how it is written. So most
  of the time went on reading source by hand along the runtime paths.

The suite was **not** run for this audit. Nothing was changed.

## Summary

| # | Sev | Finding | Where |
|---|---|---|---|
| 1 | **High** | Godmode is written but nothing reads it. Admin godmode does nothing, and onboarding "isolation" leaves new players able to take damage | `AdminActionSystem.lua:138,263`; nothing in `Server/Combat` |
| 2 | **High** | No code ever sets `profile.faction`, so 3 of the 4 art trees are permanently `WrongFaction` for every player | `PlayerDataSystem.lua:223`, `ArtSystem.lua:158`, `FactionManager.lua` (stub) |
| 3 | **High** | Character creation commits the profile before checking the character and spawn exist. A failure afterwards strands the player frozen in the Threshold for the session, and onboarding cannot be retried | `CharacterCreationSystem.lua:495-527` |
| 4 | Med | A censored display name (`####`) is accepted and saved permanently. There is no rename path | `CharacterCreationSystem.lua:481-497` |
| 5 | Med | While a realm stands, every hotbar slot that is on cooldown skips the local drop, not just the domain's own slot. Those presses supersede a legitimately buffered press on the server | `AttackInputClient.lua:295`, `AttackRequestSystem.lua:1355` |
| 6 | Med | Fast settings changes are silently dropped by the server (4/s shared bucket, no trailing write), so the saved value differs from what the player last set | `SettingsSystem.lua`, `SettingsConstants.lua:123`, `SettingsClient.lua:607-644` |
| 7 | Med | Returning players never get a `RespawnLocation`. Every later respawn uses Roblox's random pick, which may include the Waking Threshold `SpawnLocation` | `CharacterCreationSystem.lua:415` |
| 8 | Low | Emote stop shares the play rate-limit bucket. The gamepad stick fires `RequestStop` every frame until the echo arrives, which eats the bucket and drops the next `RequestPlay` | `EmoteWheelClient.lua:247`, `EmoteSystem.lua:378` |
| 9 | Low | Admin "invisible" restores every part to `Transparency = 0`, so originally-invisible parts become visible. Parts added while invisible (a drawn weapon) are never hidden | `AdminActionSystem.lua:108` |
| 10 | Low | `GetSettings` answers a rate-limited call with the defaults, as if they were the player's settings | `SettingsSystem.lua:146` |
| 11 | Low | A frozen player can still attack, block and parry. `Frozen` is read only by RunSystem and the parkour client | `RunSystem.lua:296`; no combat reader |
| A1 | Arch | Dead code: 3 unregistered parkour states (376 lines) and `UI/Components/ActionIcon.lua` (483 lines) | see §3 |
| A2 | Arch | BlimpSystem and BoatSystem still carry byte-identical mount helpers outside `Server/Vessel` | see §3 |
| A3 | Arch | Client boot has no isolation: one `Start()` that throws aborts every later module | `Main.client.lua` |
| A4 | Arch | 6 client folders are not in `test.project.json`, so `SettingsClient` (finding 6) and the onboarding client can't be specced | see §3 |
| D1-D4 | Design | Progression pillars still unbuilt; a tier-up changes nothing about how you fight; a realm-cancel UX gap; parry timer copy | see §4 |

## Status: fix pass of 2026-10-25

| # | Status | What changed |
|---|---|---|
| 1 | **Fixed 2026-10-25** | `Shared/Combat/Invulnerability.lua` reads `Godmode`; `DamageResolver.ApplyScales` zeroes Damage/GuardDrain/Hitstun for an invulnerable defender (last stage); `DamageSystem.applyOutcome` and `ApplyImpact` pass it; `AirComboSystem.isLaunchImmune` honours it. `AdminActionSystem` header now names the real reader. Specs land real hits (swing and `ApplyImpact`) and assert Health/guard. Knockback launch of a godmode body is NOT suppressed (see new issues). |
| 2 | **Open** | Needs a design decision (out of scope for this pass). |
| 3 | **Fixed 2026-10-25** | `handleFinalize` resolves the character and the arrival CFrame before the `Transform`; a failure there commits nothing and stays retryable. Header contract updated. |
| 4 | **Fixed 2026-10-25** | A filtered name that differs from the validated input returns `NameFiltered` without committing; `OnboardingClient.describeFinalizeFailure` shows it and sends the player back to `NameEntry`. |
| 5 | **Fixed 2026-10-25** | `AttackInputClient.requestHotbar` bypasses the local cooldown drop only for the slot whose `moveId` equals `OwnRealm.Get().MoveId`. |
| 6 | **Fixed 2026-10-25** | New `Client/Settings/SettingsWriteCoalescer.lua` (latest value per remote+field, 0.3 s trailing debounce, `SettingsConstants.WriteCoalesceSeconds`); every "set field" write in `SettingsClient` goes through it, apply-locally-first unchanged. Rebinds and resets still send directly. Spec added. |
| 7 | **Fixed 2026-10-25 (needs place check)** | `pointRespawnAtArrival` is shared by Finalize and the returning-player branch of `handleGetOnboardingState`. The Threshold `SpawnLocation` must still be `Neutral = false` or `Enabled = false` in the place file: not verifiable from source. |
| 8 | **Fixed 2026-10-25** | `EmoteController` latches one stop per active emote (reset when the active emote changes); `handleRequestStop` has its own limiter (`EmoteConstants.MaxStopRequestsPerSecondPerPlayer`). |
| 9 | **Fixed 2026-10-25** | Invisibility records each part's/decal's original Transparency and restores it; a `DescendantAdded` connection in a Trove on the override state hides parts added while invisible; cleaned on un-invisible, respawn and leave. Specs added. |
| 10 | **Fixed 2026-10-25** | `GetSettings` has its own limiter (`GetMaxCallsPerSecondPerPlayer = 2`); when limited it returns nil, which the client already treats as a failed fetch, never the defaults. |
| 11 | **Fixed 2026-10-25** | `Shared/Combat/FrozenBody.lua`; `AttackRequestSystem` body gate refuses `"Frozen"`, `DefenseSystem.SetBlocking` (press only) and `BeginEvade` refuse a frozen body. |
| A1 | **Fixed 2026-10-25** | Deleted `States/{Rolling,AerialCombat,WallJumping}.lua` and `Components/ActionIcon.lua` after confirming no requires; `HoverLabel`/`Button` comments updated. `HoverLabel` now has no caller either (open). |
| A2 | **Open** | Later. |
| A3 | **Fixed 2026-10-25** | `Main.client.lua` `boot(name, module, ...)` runs each `Start` under `xpcall` + traceback, logs through the `Main` scope and continues. `StartMenuClient.Run`/`LoadingClient.Run`/`IntroClient.Run`/`UI.Mount`/`RestoreSettings` are deliberately still bare: they gate everything after them. |
| A4 | **Fixed 2026-10-25** | `Client/{Announcement,BugReport,Intro,Onboarding,Settings,StartMenu}` mapped in `test.project.json`. `Client/Camera` was ALREADY mapped there when this pass began (the audit's "excluded on purpose" note was out of date); left as found. |
| A5, D1-D4 | **Open** | Later / design. |

> **Correction (cohesion audit, 2026-10-25).** A3 above says "the server already has `boot(name, module)`" as if it isolated a throwing Init. It does not: `Main.server.lua`'s `boot` calls `system.Init()` bare, so one throwing `Init` aborts every later System **and** the closing `AssertBootComplete`, the check that exists to name what did not boot. Only the client wrapper isolates. See `2026-10-25-cohesion-audit.md`, A9.

---

## 1. Bugs

### 1. Godmode is enforced by nothing — High

`AdminActionSystem.ApplyGodmode`/`SetGodmode`/`ReapplyRespawnOverrides` write `AttributeConstants.Godmode`.
A tree-wide search finds **zero** readers. No combat layer, `DamageSystem`, `DamageResolver`, `ApplyImpact`
or AirCombo checks it. The header (`AdminActionSystem.lua:23`) says "the combat layer's own godmode check reads
the Godmode Attribute". That check lived in the deleted `CombatSystem` and was not rebuilt. It went the same way
as the emote combat gates EmoteSystem's own header lists.

Two consequences:
- The admin panel's Godmode toggle sets a flag, and the Inspector shows "GODMODE". The player still takes full
  damage. `AdminActionSystem.spec` asserts the Attribute, not the effect. Two components agree with each
  other, and the consumer that should act on it doesn't exist.
- **Onboarding isolation is two-thirds real.** `CharacterCreationSystem` sets Frozen + Godmode + Invisible
  on a first-time player (`:410-412`). It keeps all three through the awakening beat after `PivotTo` the race's
  arrival spawn (`:525`), which is the live world. The player stands frozen and invisible, but anyone swinging at
  the spawn can hit them. Kill credit and progression rewards then work as normal.

**Fix.** One predicate in `Shared/Combat` (e.g. `Invulnerable(humanoid)`, reading `Godmode`). Read it in
`DamageSystem` before pricing: a stage in `DamageResolver.ApplyScales` that zeroes `Damage`, `GuardDrain` and
`HitstunSeconds`, which is the documented place for post-pricing multipliers. Read it in `ApplyImpact`, and in
AirCombo's launch eligibility (`isLaunchImmune`). Add a spec that lands a hit on a godmode body and asserts
Health is unchanged, not just that the Attribute is set.

### 2. Faction is never assigned, so faction trees are unreachable — High

`profile.faction` defaults to `nil` (`PlayerDataSystem.lua:223`). Its only writer is the decode at `:857`, which
round-trips whatever was stored, and that has always been nil. `FactionManager.Init` is empty.
`ArtSystem.CanUnlock` refuses with `WrongFaction` unless `tree.Faction == profile.faction`
(`ArtTreeManager.IsTreeOpenTo`). Three of the four trees in `ArtConstants.ArtTrees` name a faction (Ascendant
Palm, Devouring Fist, Wandering Step). So for every non-admin player, only Foundation Forms can ever be
unlocked. The catalogue's `LockedReason` correctly reports the refusal, so the Arts tab shows those trees as dead
rows.

`ArtConstants.lua:55` explains why the common tree exists ("before any faction identity exists"). It does not
say the faction trees are meant to stay sealed.

**Fix (needs a design call).** Pick how a player gets a faction: derived from race at Finalize, chosen at
onboarding, or earned. Then make `FactionManager` the one writer. The bible's three-faction pillar is the canon
reference. Until then, consider leaving the faction trees out of the catalogue rather than showing locked
content nobody can open.

### 3. Finalize commits before it can fail — High

`handleFinalize` validates the request, then commits `raceId`, `displayName` and `attributes` (`:495`). Only
after that does it check `player.Character` (`:510`) and `resolveArrivalCFrame` (`:517`). If either fails:
- the profile is already onboarded, so a retry returns `AlreadyOnboarded` (`:444`);
- `awaitingAwakeningPlayers[player]` is never set, so `AwakeningComplete` is ignored;
- Frozen, Godmode and Invisible are never cleared. The player is stuck frozen in the Threshold for the rest of
  the session.

**Fix.** Resolve the character and the arrival CFrame **before** the `Transform`. Neither depends on the
profile write. A failure then leaves the profile un-onboarded and retryable.

### 4. Censored names are accepted permanently — Med

`TextService:FilterStringAsync(...):GetNonChatStringForBroadcastAsync()` replaces filtered characters with `#`.
That result is saved straight to `profile.displayName` (`:493-497`). There is no rename path anywhere (the only
writer is Finalize), so a player whose name trips the filter keeps "########" for the life of the account.

**Fix.** If the filtered string differs from the validated input, return `Reason = "NameFiltered"` without
committing, and let the onboarding screen ask again.

### 5. Realm cancel unlocks every cooling slot — Med

`requestHotbar` (`AttackInputClient.lua:295`) skips its honest local cooldown drop whenever
`DomainRules.OwnsLiveDomain` is true. The aim was to let the domain move's own press reach
`DomainSystem.TryCancel`. But the condition is not scoped to that move. While a realm stands, pressing **any**
art that is on cooldown:
1. plays the press cue for a press that cannot throw, and
2. sends it to the server. There it is refused as `Cooldown`, which is a `TransientRefusal`, so `rememberRefused`
   buffers it. That calls `dropBuffered(model, "Superseded")` (`AttackRequestSystem.lua:1355`), **discarding a
   press that was legitimately buffered**, such as an M1 queued mid-swing. Mashing a cooling art during your own
   realm silently eats your next string hit.

**Fix.** Bypass only for the realm's own move:
`slotCooldownRemaining(...) > 0 and not (realm ~= nil and realm.MoveId == moveId)`, using `OwnRealm.Get()`.
That is the same fact the HUD's cancel bar already keys on (`refreshCancelSlot`).

### 6. Settings writes are dropped under a 4/s bucket — Med

`SettingsSystem` uses one `RateLimiter` at `MaxCallsPerSecondPerPlayer = 4`, shared by all eight remotes. It is
fixed-window, and a limited call is dropped with no reply. `SettingsClient` applies each change locally, then
fires immediately, with no coalescing. Clicking a Stepper five times in a second (sensitivity, deadzone, UI
scale) or flipping several toggles quickly leaves the screen showing the last value while the profile holds an
earlier one. On rejoin the setting "reverts".

**Fix.** Coalesce on the client: keep the latest value per field and flush on a short trailing timer (~0.3 s),
so a burst becomes one write of the final value. A server-side "last value wins after the window" would also
work, but the client is the side that knows a burst is in progress.

### 7. Returning players have no `RespawnLocation` — Med (plausible; depends on place data)

A first-time player gets `RespawnLocation` set to the Threshold, then to the race's arrival spawn at Finalize
(`:546`). A returning player goes through the `else` branch (`:415`), which sets nothing. Every respawn in every
later session uses Roblox's default pick among enabled, neutral `SpawnLocation`s. If the Threshold spawn is one
of those, returning players can respawn into the onboarding room. Even if it isn't, the race arrival spawn
chosen at onboarding only applies in the session the character was created. That can't be confirmed from
source, because the spawns live in the place file.

**Fix.** Set `RespawnLocation` from `profile.raceId` (`ResolveArrivalSpawnPath`) on the returning-player path
too. Make sure the Threshold `SpawnLocation` is `Neutral = false` or `Enabled = false`.

### 8. Emote stop is rate-limited and floods from the stick — Low

`handleRequestStop` shares `playRateLimiter` (4/s) with play and finish. `RateLimiter`'s own header names a
stop/release as the action that should not be limited. On a gamepad, `InputChanged` on Thumbstick1
(`EmoteWheelClient.lua:247`) calls `RequestStop` every frame while the stick is past the threshold.
`EmoteController.RequestStop` only checks `activeEmoteId`, which stays set until the server's `Emote_Stopped`
arrives. So a round trip's worth of frames each fires a remote. The first gets through. The rest burn the bucket,
and a `RequestPlay` in the next second is dropped silently.

**Fix.** A per-emote "stop sent" latch in `EmoteController`, and either no limiter on stop (it is idempotent) or
a limiter of its own.

### 9. Invisibility doesn't restore what it found — Low

`setCharacterTransparency(character, 0)` (`AdminActionSystem.lua:108`) forces every BasePart (except the root)
and every Decal to 0. Parts that were authored invisible become visible when invisibility ends: weapon helper
parts, transparent accessory parts, VFX anchors. Every new player passes through `SetInvisible(false)` at
awakening. A part parented while invisible (drawing a weapon) is never hidden either.

**Fix.** Save original transparencies the first time and restore them. Hide parts that are added later with a
`DescendantAdded` connection held in the override state's life Trove.

### 10. `GetSettings` lies when limited — Low

A rate-limited `GetSettings` returns `DEFAULT_SETTINGS` (`SettingsSystem.lua:146`). The client can't tell that
from the player's real settings, and applies it. Return a result with a reason, or exempt the read. It is
called once at boot.

### 11. Frozen doesn't stop combat — Low

`Frozen` pins WalkSpeed (RunSystem) and the parkour client. No combat layer reads it, so a frozen player can
swing, block and parry. In onboarding that matters less, because the client UI owns input. For an admin freeze on
a misbehaving player, it means the freeze doesn't hold. If that is intended, say so in `AdminActionSystem`'s
header. If not, add Frozen as an `AttackRequestSystem.CanAct` refusal.

---

## 2. Verified clean (for the record)

- Every `OnServerEvent`/`OnServerInvoke` handler has a limiter or `AdminGate`. Dev-tool `wrapHandler`s are
  `RemoteHandler.Scoped`, not hand-rolled.
- No bare `RootControlLocked` writes, no stray `print`/`warn`, no yields in Heartbeat/PreRender callbacks, and
  no `table.remove` while iterating forward.
- `[Player]`-keyed state has PlayerRemoving cleanup everywhere. The one apparent miss,
  `ProjectileRelevance.Records`, is bounded by shot lifetime plus a prune.
- `PlayerDeathSystem`, `RewardSystem`, `MeridianSystem`, `TierSystem`, `InventorySystem` and `RespawnSystem`:
  the read-through found no defects.
- Last commit's broadphase fix (`CandidateGatherer`/`HitboxEngine` `localCentre.Position`) is correct, and
  `ArtSystem`'s one-art-one-slot dedupe is sound.
- Prior audit's open item still stands: `ParkourValidation.PruneRejections`/`ShouldFlag` are reached only by their
  spec.

## 3. Architecture and wiring

**A1. Dead code, about 860 lines.** `Client/Parkour/States/{Rolling,AerialCombat,WallJumping}.lua` are not in
`States/init.lua`, and nothing requires them. `WallJumping` was folded into WallRunning in `84a19d5`. The roll
was deleted with evade phase A. Commit `0f83e22` still edited `WallJumping.lua`, which is effort spent on a file
that cannot run. `UI/Components/ActionIcon.lua` (483 lines) lost its last caller in the admin rebuild. It is now
referenced only in other files' comments, and `HoverLabel`'s header still describes it as the anchor. Delete all
four and fix the header references.

**A2. Vessel duplication.** `sweepStaleMounts`, `onHullTouched`, `clearInheritedInstances` and
`cancelPendingWorldEntry` are byte-identical in `BlimpSystem` and `BoatSystem`. `broadcastMountChanged`,
`sendExistingMounts` and `mount` differ by 2-7 lines. CLAUDE.md says the two vehicles differ in "exactly two
files each". The mount registry and hull-contact bookkeeping are a third shared piece that hasn't moved into
`Server/Vessel/` yet. A `VesselMountRegistry.New(config)` there would remove ~120 lines and the risk that a fix
lands in only one of the two.

**A3. Client boot has no isolation.** `Main.client.lua` calls about 40 `X.Start()` in sequence. One throw
(say an index on a `WaitForChild` that timed out) aborts every later Start: a broken `FOVOffset` takes parkour,
combat input and the HUD with it, and nothing in the Live Console names the cause. The server already has
`boot(name, module)` and `AssertBootComplete`. Give the client the same `boot` wrapper: pcall each Start, log
through the scoped logger, and keep going. A partial client the console can explain beats a dead one it can't.

**A4. Test-place gaps.** `Client/{Announcement,BugReport,Intro,Onboarding,Settings,StartMenu}` are not mapped in
`test.project.json` (`Client/Camera` is excluded on purpose, per the existing note). Findings 6 and 8 sit in
code the suite can't load.

**A5. Big files to watch.** `AttackRequestSystem` (1989 lines), `EnvironmentProbe` (2030),
`ParkourConstants` (2127), `PlayerDataSystem` (1878) and `BlimpSystem` (1664). None is wrong because of its size.
Two of them show seams worth splitting next time they're touched: AttackRequestSystem's press/buffer machinery
(Press, rememberRefused, dropBuffered, answerRefused and the claimer) is a self-contained `PressBuffer`. The
PlayerDataSystem lock/generation decision functions are already pure and already called out in its header.

## 4. Design

**D1. The progression pillars are still empty.** `AbsorbSystem`, `AwakeningSystem`, `AchievementSystem`,
`TerritorySystem`, `WorldSystem` and `FactionManager` are all `Init() end`. Absorb is the bible's named
fight-to-grow incentive, and faction is a prerequisite for both D2 and finding 2. Recommended order: Faction,
because it unblocks arts, Qi Conflict and territory, then Absorb, because a kill currently pays only Meridian XP.

**D2. A tier-up doesn't change how you fight.** `progression-systems.md` says each tier-up "should change *how*
a player plays". Today a tier gates art unlocks (`RequiredTier`), but with faction trees sealed (finding 2) that
is one tree's worth of content. `CombatPowerConstants.Enabled = false`. In practice, tiers 2-9 are a badge.

**D3. Realm cancel: an early press says nothing.** A domain press before `CancelableAt` falls through to a
`Cooldown` refusal. That is by design, but the player gets no feedback beyond the countdown digits on the slot.
A short "not yet" pulse on the slot would explain why nothing happened. That press is also the one finding 5
lets supersede a buffered M1.

**D4. Parry timer copy.** `ParryTimer` labels both lockouts "PARRY  0.4s". The two gaps it renders mean
different things (`Recovery`: you whiffed; `GuardRelease`: you only just let go). `Readiness.Kind` is already
there, so a different word or colour per kind teaches the rule instead of just timing it.

## 5. Suggested order

1. Findings 1, 3, 5. Each is small, contained and high-impact.
2. Finding 2 and D1 (faction), which need a design decision first.
3. Findings 4, 6, 7, then A1 (deletion) and A3 (client boot wrapper).
4. The rest as each area is next touched.
