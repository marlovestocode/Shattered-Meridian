# Combat state, swap rule and movement checks — 2026-10-08

Scope: the weapon-swap cooldown and the movement sanity checks the bible asks for, plus an audit of the
combat state/tag pipeline (EngagementSystem, the body-lock Attributes, the automated cheat detectors).
Everything below was verified against source on this date.

## 1. Weapon swap rule

**Before.** Two live swap paths. The legacy `AttackConstants.RemoteNames.SwapWeapon` remote let a client
pick ANY roster weapon, guarded only by a 4/s rate limit; swapping reset the combo string, which made
weapon-cycling a free string reset. `CombatConstants.SwapCooldownSeconds` existed with no reader.

**After.** One path: `WeaponInventorySystem` (draw/sheathe, next weapon) →
`AttackRequestSystem.RequestWeapon(model, weaponId, now) -> (ok, reason?)`.

- Refused while the body cannot act (`AttackRequestSystem.CanAct`: stunned, grabbed, held, dead), with
  that gate's own reason; refused while the engine is not Idle (windup, active, recovery) — `"Busy"`.
- While engaged (`WeaponConstants.Swap.OnlyWhileEngaged`) a swap starts a
  `WeaponConstants.Swap.CooldownSeconds` (4 s) cooldown; a second swap inside it is `"SwapCooldown"`.
  Out of combat, swaps are free.
- A refusal rolls the inventory change back and pushes the inventory with `Refused`/`SwapReadyIn`, which
  `WeaponInventoryClient` turns into a toast.
- Legacy remote, its rate limiter and the orphan constants are removed.

## 2. Movement sanity checks (`Server/Combat/MovementGuard.lua`)

Lag compensation tests swings against server-recorded positions, so a client writing its own position
bends hit registration. MovementGuard samples ENGAGED players at 10 Hz and judges each through the pure
`Shared/Combat/MovementJudge.lua` (specced headless):

- **Speed** over a 0.5 s window against `WalkSpeed × 1.35 + 4 studs` — or ParkourValidation's travel
  ceiling while a validated parkour action owns the body — carrying the best allowance of the last
  second so a dash's glide isn't judged against WalkSpeed mid-ramp.
- **Rise** faster than 40 studs/s averaged over a window (not judged during parkour climbs).
- **Teleport**: one step over 20 studs and 2.5× the allowed speed since the last real change.
- **Excused** (track reset) while the server holds or moves the body: `RootControlLocked`, Grabbed,
  Mounted, Flying, anchored/PlatformStand, dead, `KnockbackUntil` (launches, realm pulls, admin
  teleports now stamp it), air-combo holds.

A strike suspends the lag-compensation benefit of that player's OWN swings for 5 s
(`HitboxEngine.SuspendCompensation`); 12 weighted strikes in 90 s (a teleport weighs 3) flags the player
once per session for moderation (`ReasonCode = "MovementImplausible"`). Nothing is kicked or corrected.

## 3. Combat state audit — findings and fixes

| # | Finding | Fix |
|---|---|---|
| 1 | `RootControlLocked` had five independent writers (swing lock, defence, grab victim/thrower, air combo, vessel). Each wrote `true`/`nil` blind, so the first release unlocked a body another system still held (e.g. a stagger ending mid-grab). | `Server/Combat/RootControl.lua`: a claim set per Humanoid; the Attribute is true while any owner holds a claim. All five writers migrated. |
| 2 | Legacy swap remote allowed any roster weapon (see §1). | Removed. |
| 3 | `KnockbackAudit` and `ParkourSystem` each hand-rolled strike counting and flagging; both flagged without a reason code and could overwrite a manual admin flag. | `Server/Systems/Support/SuspicionLedger.lua` + `ModerationSystem.ReportAutomated` (never overwrites an existing flag). Three detectors now share it. |
| 4 | Realm Hitstun/GuardDrain/Pull/Push pulses never tagged anyone — they resolve no DefenseOutcome, so `DamageSystem.OnApplied` never fired. A player locked in a realm's stun field was "out of combat": parkour's gate let them leave, MovementGuard didn't watch them. | `EngagementSystem.RecordPressure` / `RecordPressureBetween`, called through DomainSystem's `Pressure` port for every body a non-damaging pulse reached. Keeps the last real `LastOutcomeKind`. |
| 5 | A killed player's tag ran its full duration across the respawn: the HUD said "in combat" on a fresh body with no `InCombat` Attribute. | `EngagementSystem.ClearPlayer` bound to `GameplayEvents.OnPlayerKilled` for the victim (the killer keeps theirs). |
| 6 | `InCombat` is written only on an edge; a body that spawns mid-tag (admin respawn, `LoadCharacter`) never got it. Players present before `Init` were never seeded in the ChangeNotifier. | EngagementSystem binds through `PlayerLifecycle.BindAllPlayers`, re-asserting the Attribute on each new body while a tag is live. |
| 7 | Admin teleport during a fight would read as a cheat teleport. | `AdminActionSystem` stamps `KnockbackUntil` for 2 s on a teleport. |

## 4. Left open

- `ParkourValidation.PruneRejections` / `ShouldFlag` are now production-unused (ParkourSystem uses
  SuspicionLedger); only their spec reaches them. Delete with the spec cases when convenient.
- A vessel dismount does not stamp `KnockbackUntil`; the track resets at dismount, so only momentum
  carried off a moving hull could strike. Watch for it in playtests.
- MovementGuard watches; it cannot stop a client moving its own body. A server-authoritative character
  controller is the only full answer and is out of scope for this pass.
