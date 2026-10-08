# Combat pipeline pass — 2026-10-08

Scope: frame cost and timing of the combat pipeline (HitboxEngine → DefenseSystem → DamageSystem →
AttackRequestSystem, plus the client input path). Findings already closed by the 2026-09-28 audit and the
2026-10-06 feel pass were not re-raised. Seven changes, landed easiest first, one commit each.

**Not yet verified in Roblox.** Every change was linted (selene: 0 warnings, 0 parse errors on the touched
files) and formatted (stylua), and new specs were written, but the TestEZ suite has not been run against
these commits. Run it before merging, and take a MicroProfiler capture of a 3–4 player fight before and
after (visualiser off), looking at the new `CombatTick` / `Combat.<Phase>` labels.

## 1. Two substeps per ordinary frame, not three

`HitboxEngine.Step` divided a frame by `ceil(frame / MinSubstepSeconds)`. A real 60 Hz Heartbeat runs a hair
over 1/60 (0.01667–0.0170 s), so that came out at 3 on almost every frame: a third state-machine pass,
sample and broadphase per active swing, buying sampling ~0.2 ms finer than authored.
`HitboxEngineConstants.SubstepOvershootTolerance` (0.25 of a substep) absorbs Heartbeat jitter;
`HitboxEngine.SubstepsFor` is public and spec-pinned. Long frames still subdivide up to the cap.

## 2. SwingTracking turns the body before physics

The windup turn wrote `root.CFrame` on Heartbeat, after the physics step, so it reached the simulation a
frame late and fought the Humanoid's own rotation. It now runs on `PreSimulation` (GrabHoldPose's precedent).

## 3. Buffered M1 links start frame-exact

A buffered predicted swing fired from `task.delay(freeAt - now)`, which resumes up to a frame after the gate
opens, by a different amount each link, so a mashed string's local rhythm wobbled against the server's
Heartbeat-exact flush. `AttackInputClient` now watches the buffered press on `PreRender` (connected only
while one is buffered), backdates the swing to `FreeAt`, and starts the clip that far in through the new
`AnimationManager` `ClipSpec.StartOffsetSeconds` (capped at one 30 fps frame).

## 4. One Combat_Feedback batch per player per frame

`DamageSystem.sendFeedback` fired once per contact per participant; a multi-target swing, a volley or a
realm pulse sent the attacker several remotes in one frame. Feedback is now queued per player and flushed
once at the end of `DamageSystem.Step` — the same Heartbeat the contacts resolved in, so nothing arrives
later. `Shared/Damage/FeedbackBatch.lua` owns the wire shape (and still accepts a lone payload); both
listeners (`CombatFeedbackClient`, `MoveEditorClient`) unpack entries in order.

## 5. One broadphase per swing per frame

Bodies move once per physics step, so every substep of a frame queried identical target positions. Each
swing now gathers once per frame (`frameCandidates`): a sphere round the segment from the previous sample's
pose to this frame's end pose, padded by the volume's circumradius, the broadphase margin and the rewind
allowance. Every substep pose lies on that segment, so the narrow phase still sees an exact superset.
Charging volumes still gather per substep.

## 6. Hurtbox broadphase, no Workspace queries

`CandidateGatherer` no longer calls `GetPartBoundsInBox`/`InRadius`. It indexes each registered body's own
parts (root plus direct-child BaseParts, kept live from `ChildAdded`/`ChildRemoved`) and gathers by a
root-distance reject against the body's measured reach (`HurtboxReachPadStuds`), then a per-part bound
test. Effects:

- no spatial query, no result-array allocation and no `IsA` per gather; a shot in empty space costs a few
  distance checks (projectiles use the same index through `Gather`);
- **behaviour change:** accessories and the held weapon are no longer hit candidates. Striking someone's
  sword used to count as hitting them, and a hat reached further than the head;
- equipment no longer crowds `MaxCandidatesPerSample`, which could saturate (silently dropping hits) with
  three or four armed fighters inside one hitbox.

## 7. One ordered CombatTick

The nine combat Systems with a Heartbeat (HitboxEngine, Defense, Damage, AttackRequest, Grab, AirCombo,
Engagement, EnvironmentReaction, Domain) relied on boot order for frame order. They now register a phase
with `Server/Combat/CombatTick.lua`: one connection (made by the engine at its existing boot slot), one
explicit `PHASES` list, one shared clock per frame, each phase `xpcall`'d so one erroring System cannot stop
the rest, each under a MicroProfiler label, and a warning for a phase over half a frame. Grab's
PreSimulation pin, and TrainingBotSystem (booted after the movement Systems), keep their own connections.

## Left open

- TrainingBotSystem could join the tick as a late phase; left out because it currently runs after
  ParkourSystem/RunSystem's Heartbeats, and moving it ahead of them is a behaviour change worth a playtest.
- Measured numbers for `performance-optimization.md`'s budgets, once a capture exists.
