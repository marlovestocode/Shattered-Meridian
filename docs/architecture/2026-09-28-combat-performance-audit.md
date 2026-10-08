# Combat Performance & Fluidity Audit — 2026-09-28

Scope: what runs, and what goes over the network, while two players fight. Prompted by a playtest
report: FPS drops during 1v1 fights, excessive remotes, and combat that doesn't feel fluid.

Every finding is marked **CONFIRMED** (read in current source) or **LIKELY** (the code path is
confirmed, but whether it is the *dominant* frame cost needs a MicroProfiler capture). No code was
changed by this audit. Earlier client-perf findings (2026-08-19) were not re-audited; see that
audit's own status block.

## Status (updated 2026-09-28, same day)

Fixed: **L1** (swing animation is now client-predicted, see `AttackInputClient.lua`'s header),
**L2** (hit-stop freezes Action-priority tracks only), **L3** (combat pins the run to walking and
holds the gear instead of zeroing it, and a hit no longer drops the sprint key), and **N2** (the
server lunge skips player attackers).

**Update 2026-10-07:** F2–F5 and N1 are fixed too, and have been since the 2026-10-06 feel pass
(`2026-10-06-combat-feel-pass.md`, top); this status line was never updated. Re-verified against source:
`FX/HitFlash.lua` keeps one Highlight per body and only enables/tweens it (F2), `UI/Screens/CombatFeedback`
mutates a stack's own Value (F3), `FX/AttackTrail.lua` builds its trail once and reparents it (F4), and
`EngagementSystem.publish` pushes on an edge or an opponent change and otherwise coalesces to
`EngagementConstants.Network.MinPushIntervalSeconds` (N1, which also retires F5). Only **F1** (the debug
visualiser) is untouched, by design -- it is off in a real server.

Same day, on top: homing re-syncs and swing scuffs moved to UnreliableRemoteEvents
(`NetworkBridge.CreateUnreliableRemoteEvent`; `Attack_ProjectileSync`, `Combat_EnvironmentFXCosmetic`), and
lag-compensated hits landed (`HitboxEngineConstants.LagCompensation`).

The same pass closed a state hole found alongside these: a guard could be raised mid-swing, or
during hitstun. `DefenseSystem` now holds that press until the body is free, and `DefenseClient`
defers the guard animation to match. Parried and traded swings are now also cut on the attacker's
own client, since the server was already cancelling them.

## 0. Before measuring anything: the hitbox visualiser is on

The playtest screenshot shows the red hitbox volumes, which means the Dev Menu's server-wide toggle
(`HitboxEngine.SetDebugVolumesEnabled`) was on. That alone is a real per-swing cost for **every
client in the server** (finding F1). Turn it off before judging FPS, or every other number is
contaminated.

## 1. Frame-rate (client)

### F1 — Debug hitbox volumes build and destroy a Highlight per swing — CONFIRMED (debug-only)

`HitboxEngine.lua:220` `showDebugVolume` creates a server Part **plus an AlwaysOnTop `Highlight`**
the first time a swing samples, and `endActiveWindow` (`:657`) destroys both when the Active window
closes. Every swing therefore replicates an Instance create and destroy to every client, and its
CFrame is rewritten on every substep (up to `MaxSubstepsPerFrame = 8` per Heartbeat). In an M1 trade
that is several Highlight builds and teardowns a second, on every machine. The cost disappears when
the toggle is off.

Fix if the tool should stay usable mid-fight: keep one Part per combatant parented for life, toggle
`Transparency` instead of destroying, and write CFrame once per Heartbeat rather than per substep.

### F2 — Hit-flash reparents an AlwaysOnTop Highlight onto the victim every hit — CONFIRMED path, LIKELY cost

`FX/HitFlash.lua:103` acquires a pooled Highlight, sets `Adornee = model` and reparents it on
**every** resolved contact. Both participants' clients do it, since both receive `Combat_Feedback`.
Pooling saves the Instance allocation, but not the engine's work of rebuilding the outline for a
fresh adornee. Highlights are one of the most expensive per-object render features Roblox has.

Fix: one persistent Highlight per character (adorned once, left parented at full transparency),
with a hit only tweening its transparency.

### F3 — Damage-number stacking rebuilds the label every hit — CONFIRMED

`UI/Screens/CombatFeedback/init.lua:142` `addDamageHit` clones the whole `damageNumbers` table and
writes a **new** table at the same key on every stacked hit. `ForPairs` (`:221`) sees a changed
value, so it destroys that entry's scope and builds a fresh `DamageNumberLabel`, springs included,
on every hit of a combo.

Fix: give each stack entry its own `Value` for its text and mutate that. The keyed table only
changes when a stack opens or closes.

### F4 — Swing trail allocates three Instances per swing — CONFIRMED, minor

`FX/AttackTrail.lua:139` creates two Attachments and a Trail on every `Attack_Started` and destroys
the previous set. That breaks the pooling rule in `performance-optimization.md`.

Fix: build once per character and anchor part, then toggle `Trail.Enabled`.

### F5 — Engagement HUD recomputes on every hit — CONFIRMED

`UI/State/ClientState.lua:432` writes a fresh table into `state.Engagement` for every
`Engagement_Changed`, which N1 below shows arrives on every hit. Every Computed and Observer
downstream (`HUD/EngagementDetail.lua:160,167`, `HUD/init.lua:382`) re-runs each time. This is fixed
for free by N1.

## 2. Network

### N1 — Server→client remotes per landed hit, and the one to cut — CONFIRMED

Per landed hit in a 1v1:

| Remote | Count | Source |
|---|---|---|
| `Combat_Feedback` | 2 (attacker + defender) | `DamageSystem.lua:343,349` |
| `Engagement_Changed` | 2 (**unconditional**) | `EngagementSystem.lua:264` via `RecordExchange` `:483,:488` |
| `Defense_StateChanged` | 0–1 (block/guard drain, state edge) | `DefenseSystem.lua:492,613` |

Plus `Attack_Started` once per swing, passive Qi at up to 2/s per player
(`QiConstants.PassiveSyncIntervalSeconds = 0.5`), and replicated Humanoid Attribute writes on
every swing and hit (`CombatBusyUntil` from `AttackRequestSystem.lua:505` and `DamageSystem.lua:244`,
plus `RootControlLocked`, `DefenseState`, `SprintStage`).

An M1 trade therefore runs on the order of **10+ remote events per second per player**, against the
~4/s design budget in `performance-optimization.md`.

`EngagementSystem.publish` fires `Engagement_Changed` whether or not anything a player can see
changed. The `ChangeNotifier` directly above it only gates the Attribute write, not the remote. The
HUD already counts the tag down locally (`HUD/init.lua:382`), so a per-hit push buys only
fresher dealt/taken totals.

Fix: fire immediately on the InCombat edge and on an opponent change; otherwise coalesce to a fixed
low rate (≈2 Hz). This halves the per-hit remote count with no visible loss.

### N2 — Server-side attacker lunge does nothing on a player — CONFIRMED

`DamageSystem.lua:409` calls `Humanoid:Move` on the attacker every frame of the post-hit lunge
window. Server-side movement writes on a player character are silently inert (the client owns the
body), so this is per-frame server work with no effect. The forward nudge the design describes is
not happening for players. Either delete it, or move it client-side like `SwingLunge.lua`.

## 3. Fluidity (feel, not frame rate)

### L1 — Swings start one round-trip late, and opponents see them later still — CONFIRMED

`AttackInputClient.lua:411` plays the swing clip only when `Attack_Started` arrives, which is
deliberate per that module's "no prediction" header. The consequences:

- The attacker sees their own punch **one full RTT** after pressing.
- The server opened the hitbox timeline RTT/2 after the press. Opponents see the animation only once
  the attacker's client has played it and replicated it, which is **~1.5 RTT after the server's
  timeline started**.
- Fists open their hitbox 0.19 s into the swing (0.31 ÷ WeaponSpeed 1.6). At ~150 ms ping, the
  victim's screen shows the punch starting at about the moment it has already landed.

This is nearly invisible in Studio (≈0 ms latency) and the single largest "not fluid / unfair"
factor on a real server. It is a design decision, not a bug. The options:

- **(a) Play the clip on the server's Animator.** It replicates to every observer at once and cuts
  the opponent-side delay by the attacker's half-trip.
- **(b) Play a predicted clip on press.** The client already knows its weapon's string; the server's
  `Attack_Started` then confirms or corrects. This is cosmetic prediction only, and hit authority
  stays on the server.
- **(c) Both.**

Needs a call from the combat owner before implementation.

### L2 — Hit-stop freezes every animation on both bodies, several times a second — CONFIRMED

`FX/HitStop.lua:132` `FreezeExchange` freezes *all* playing tracks on attacker and defender,
locomotion included, for 0.06–0.14 s per hit (`FXConstants` `HitStop`), throttled only to one per
0.1 s. In an M1 trade that is a full-body stutter multiple times a second on both screens. Options:
freeze only the Action-priority attack track, or shorten or skip the freeze on Basic hits.

### L3 — Every swing and hit resets sprint — CONFIRMED (by design, worth revisiting)

`CombatBusyUntil` is stamped on every swing (`AttackRequestSystem.lua:505`) and every hitstun
(`DamageSystem.lua:244`). `RunSystem.combatCommitted` then forces walking, and the sprint gear must
be re-earned from scratch afterwards. During a fight, movement goes stop-start with every exchange.

### L4 — Clip-length sync lengthens the M1 chain if clips have long tails — CONFIRMED (2026-09-28 change)

Since `AttackConstants.Windows.SyncToClipLength`, each swing's lock is clip length ÷ WeaponSpeed.
A clip with a long follow-through now slows the chain. Trim clips, or check the boot log's
`Swing clip read` lines for each clip's length.

## 4. How to measure (do this before and after each fix)

1. Turn the hitbox visualiser **off** (F1).
2. **Network:** Developer Console (F9) → Network → Stats and Summary, during a 1v1 M1 trade. Note
   the KB/s received and the per-remote event counts.
3. **Frame time:** MicroProfiler (Ctrl+F6) during the same trade. Look for render time spikes
   (Highlights, F1/F2) versus script time in Heartbeat/RenderStepped (F3/F5).
4. Test on a real server, or with Studio's Incoming Replication Lag set to ~0.15 s. L1 does not
   exist at Studio's default 0 ms.

## 5. Recommended order

1. Visualiser off, then re-measure. Free, and removes the biggest confounder.
2. **N1** Engagement coalescing. One file, halves per-hit remotes, removes F5.
3. **F2** persistent hit-flash Highlight.
4. **F3** damage-number stack mutation.
5. **F4** trail reuse, **N2** delete or relocate the dead server lunge.
6. **L2** hit-stop scope, a quick feel tuning pass.
7. **L1** decide on server-side or predicted swing animation (architecture call).
8. **F1** make the visualiser cheap, only if it needs to stay usable mid-fight.
