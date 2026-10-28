# W11 presentation owners: migration list (draft for approval, 2026-10-27)

Nothing here is built. CLAUDE.md ("Extend, migrate, never fork") asks for a written list of every consumer, what happens to
each, and what is deleted, before a replacement starts. Source for the facts: `2026-10-27-frame-order.md` P1-P3, re-checked
against current source today. Each part is independent and lands as its own branch step, with the old mechanism deleted in the same step.

## Status (2026-10-27)

Part A, Emote and Flight: DONE, not yet run or played. `Client/FX/LocalAnimator.lua` holds the one local-player manager
(`Bind` idempotent per character); `EmoteAnimator` and `FlightAnimator` are claims on it; `GetPreloadInstances` became
`GetPreloadIds` on both, with `AssetPreloader` updated; `AnimationManager`'s header names the remaining exceptions.
`load_animation_bypass` 6 -> 4 (ratchet lowered). CombatAnimator, Part B and Part C are untouched.
Behaviour differences to watch: tracks now load on first claim instead of at bind (AssetPreloader still warms the
content), and the Duration-drift warning reads the length through `GetPlayback`.

## What re-checking changed

- **P1 (CameraRig) is mostly overtaken.** The camera pass (`2026-10-27-camera-motion.md`) gave the camera one value per slot and
  put rotation behind `CameraRotationComposer`, offsets behind `CameraOffsetComposer`, and the combat camera behind `CombatCamera`.
  The "six writers excluding each other through flags" description predates that. Recommend: do not build `CameraRig`. Re-audit
  the remaining raw `Camera.CFrame` writers (below) and only close real gaps.
- **P3's header is still false in two places.** `AnimationManager.lua` lines 44 and 1136 name `Client/FX/LocalAnimator.lua`, which
  does not exist (`cohesion-report.py` allow-lists it too). The header also says "nothing else touches an AnimationTrack directly";
  six `:LoadAnimation(` sites outside it say otherwise.
- **P3 undercounts.** The six bypass sites are `EmoteAnimator:151`, `CombatAnimator:274` and `:390`, `FlightAnimator:105`,
  `IntroClient:93`, and `DevTools/MoveEditor/ClipScrubber:103`. The last two were never named.

## Part A. AnimationManager finished (P3)

AnimationManager's real client consumers today: `AttackInputClient`, `DefenseClient`, `HitStop`, `ParkourAnimator`
(server: `GrabSystem`, `TrainingBotSystem`).

| Consumer | Today | Proposed |
|---|---|---|
| EmoteAnimator | own tracks, own bind, `LoadAnimation` | move to AnimationManager claims on a FullBody layer |
| FlightAnimator | own tracks, `LoadAnimation`; CombatAnimator reads the `Flying` Attribute to stand down | move to claims; the Attribute peephole in CombatAnimator is deleted |
| CombatAnimator | own tracks, two `LoadAnimation` sites, armed-idle loop | move last, onto the Locomotion layer (see risks) |
| IntroClient | one-off cutscene clip | exempt, named in the header |
| ClipScrubber (dev tool) | scrubs a clip by hand | exempt, named in the header (never ships in `live.project.json`) |
| `LocalAnimator.lua` | does not exist | create it as the thin local-player binder the header already describes, or delete both header mentions. Recommend create: it is where layer names live |

Deleted when done: the three animators' private track tables, binds and Heartbeats; `AnimationTrackUtil`'s evaluator once nothing
uses it (the plan's wording; I have not yet checked its callers). Ratchet: `load_animation_bypass` 6 -> 2, and the two exemptions
become named rows.

**Risks, from the CLAUDE.md memory notes.** Core is the lowest animation priority and drawn weapons are Tools whose `toolnone`
pose masks Core clips; the game is R6-locked; AnimationManager has a freeze guard (`AnimationFreezeGuard.spec`) that HitStop depends
on. Migrating CombatAnimator can regress any of these silently, so it needs the plan's spike first and a playtest.

## Part B. Absolute claims on TransformLayer (P2)

| Writer | Today | Proposed |
|---|---|---|
| GuardStrainPose, HitFlinchPose | additive, through TransformLayer | unchanged |
| GrabHoldPose | writes `Motor6D.Transform` absolutely | becomes an absolute claim |
| VesselArmPose, VesselPilotPose (via `BlimpController`, `BoatController`) | write absolutely; PilotPose also writes RootJoint, which HitFlinch composes onto | become absolute claims |

New: `TransformLayer.Claim(joint, owner, cframe)` ranked above additive layers; additive offsets compose onto the claimed value.
Deleted: the direct `Transform =` writes in the five modules. Symptom today: none reported (inferred from source), so this is
preventive. A pilot taking a hit is the case to playtest. Render priorities for these are already in `FrameOrder` (Character+1 clash
row is still pinned).

## Part C. Camera (P1, narrowed)

No `CameraRig`. Instead: list the modules that still assign `Camera.CFrame` or `CameraType` outside the composers (candidates from
today's grep: `IntroCamera`, `FlightController`, `FlightCamera`, `BlimpCamera`, `PlacementCamera`), and for each decide whether it
belongs behind a composer or is a legitimate whole-camera owner (intro, placement). I have not read these files yet; this is the
one part where I would read first and report before deciding anything.

## Decisions I need from you

1. Part A: create `LocalAnimator` (recommended) or narrow the header and stop at a doc fix (P3 option B, effort S).
2. Part A order: Emote -> Flight -> Combat as the plan says, with CombatAnimator only after a spike you can playtest.
3. Part B: build now (effort M, preventive, no reported bug) or defer until it bites.
4. Part C: agree P1 is superseded and I only audit.
