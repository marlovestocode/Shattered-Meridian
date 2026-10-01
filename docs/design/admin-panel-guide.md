# Admin Panel Guide

The admin panel (Equals key, whitelist-gated) is the live-server control tool: see who is in the
server, act on any one of them, put things into the world, look after the server itself, triage bug
reports, and tune flight live. Rebuilt 2026-09-29 on the Move Editor's frame.

Code: `Client/UI/Screens/DevTools/DevMenu/` (screen), `Client/DevTools/DevMenu/DevMenuClient.lua`
(driver), `Server/Systems/DevMenuSystem.lua` (authorization + handlers), `Shared/Admin/` (wire types
and formatting).

## Layout

```
┌ Player · World · Server · Reports · Tuning ─────────────────────────────── × ┐
│ PLAYERS  12/20 │  (the selected tab)                     │  INSPECTOR        │
│ [filter]       │                                         │  name, @user, id  │
│ You        T3  │                                         │  VITALS  hp/qi/guard
│ Other      T1  │                                         │  COMBAT  state, engagement
│  COMBAT·GOD 42ms                                         │  CULTIVATION  tier/xp/…
│ …              │                                         │  OVERRIDES / SESSION
│ 60 fps · 1.2GB │                                         │                   │
└ ADMIN ─────────────────────────────────────────── (answer to the last action) ┘
```

- **Roster (left)** — everyone in the server, polled every 2 s. A row: display name and tier; the
  flags that matter (DEAD, COMBAT, FLAGGED, MUTED, GOD, FLY, FROZEN, HIDDEN, x-speed, BOUNTY) or
  their @username; ping (amber past 150 ms, red past 300); and a health hairline. You are always
  first. The footer line is the server's pulse (fps, memory, uptime). **Selecting a row makes that
  player the target.**
- **Inspector (right)** — the selected player, polled every second: vitals, defense state and
  engagement, cultivation (tier, Meridian XP through the tier, race, faction, bloodlines, rerolls,
  corruption, deviation risk), active overrides, ping, account age, position. It is the server's word
  only — nothing is predicted from a button press.

## Tabs

| Tab | What it does |
|---|---|
| **Player** | Everything aimed at the selected player, named on the plate at the top. Overrides (Godmode, Frozen, Flight, Flight collides, Invisible, walk speed); movement (go to them, bring them, spectate, respawn); vitals (restore health & Qi, kill); grants (Meridian XP presets incl. "next tier", bloodline rerolls, rare emote roll); moderation (reason, kick, mute, flag, timed ban); reset saved data. Moderation is hidden when you are the target; resetting your own data is not. |
| **World** | Sparring bots (style / difficulty / weapon) and dummies (+ server-wide guard), the server-wide hitbox-volume view, teleport to typed coordinates ("Here" fills your position), blimp fuel nodes and fill, and the vehicle catalog / berths / live list. |
| **Server** | Status (uptime, population, server fps and worst frame, memory, version — with a warning when a newer one is published — job), broadcast banner, bans by UserId (look up, lift, ban someone not here), shutdown (10 s warning) and restart now. |
| **Reports** | Bug-report triage: status / category / "claimed by me" / search filters over the loaded pages, one report open at a time with status, priority, claim, go to reporter, select reporter in the roster, and internal notes. |
| **Tuning** | Every live flight-feel field as a slider over its real range, with its file default and a per-field reset. In memory only — copy keepers into `FlightConstants.lua`. |

## Rules the panel keeps

- **The target is the roster selection.** Every Player-tab remote takes the target UserId last; nil
  means the caller. No action silently falls back to someone else if the target leaves (the server
  answers "no longer in the server").
- **Irreversible = two presses.** Kill, ban, reset saved data, lift ban, despawn all vehicles, reset
  every flight field (`Components/ArmedButton`, `Constants.Debug.DevMenu.ConfirmWindowSeconds`).
  Shutdown and restart are armed on the server instead, per admin.
- **Polls only while open**, on their own server rate-limit bucket. A tab's own data loads the first
  time the tab is shown.
- **XP and ban durations are keys, not numbers** (`XpGrants`, `BanDurations`), resolved server-side
  — a ban's expiry is on the server's clock.

## Adding a control

1. Add an `Intent` variant in `DevMenu/Types.lua`.
2. Fire it from the tab (`props.Fire({ Kind = ... })`).
3. Add a handler to `HANDLERS` in `DevMenuClient.lua`.
4. If it needs a new remote: a name in `Constants.Debug.DevMenu.RemoteNames`, a handler +
   `REMOTE_HANDLERS` entry in `DevMenuSystem.lua` (the boot manifest picks it up automatically).
