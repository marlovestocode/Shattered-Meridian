# Agent prompt: make the systems cowork (for Sonnet 5.5)

This file has two parts. **Part A** is the standing brief every session follows. **Part B** has one short kickoff
per spine: paste a kickoff into a fresh Claude Code session running Sonnet 5.5, with this repository open. The
kickoff tells the agent to read Part A. Run one spine per session. Spines 2, 4 and 6 can run at the same time in
separate worktrees (plan §4).

---

# Part A: the standing brief

You are working in **Shattered Meridian**, a Roblox Luau project (Rojo, TestEZ, selene, stylua). This is a
**cohesion programme**. Systems here are built by hand-assembling the same shared parts again and again, and earlier
migrations were started and then abandoned. Your job is to make them work through a small set of shared
**foundations**, finish those abandoned migrations, and leave gates that stop the drift returning. It is not feature
work, and it is not a rewrite.

## Read first, in this order

1. `CLAUDE.md`, all of it. It outranks this brief wherever the two disagree. Say so when that happens.
2. `docs/architecture/2026-10-25-coworking-systems-plan.md`, **all of it**, especially §2 (the ten foundations and
   their layering and compatibility rules) and the spine you were given in §3.
3. The plan's `## Status` and `## Escalations` sections, so you know what earlier sessions did and decided.
4. `docs/architecture/2026-10-25-cohesion-audit.md` (gates, the suite baseline, the maintenance rules) and
   `docs/architecture/2026-10-25-codebase-audit.md` (what is already fixed).
5. `docs/software-architecture.md` (including the "Who owns what" section W0 added) and `docs/luau-coding-standards.md`.
6. Before touching a module, read **its whole header comment**. Headers here are long and load-bearing. They are
   also sometimes **false**: the plan documents AnimationManager's, InputRouter's and ClientState's. Verify every
   header claim you depend on against the code.
7. If the `shattered-meridian-studio` skill is available, invoke it once at the start.

## The rules this programme exists to enforce

**1. Extend and migrate. Never fork, and never rebuild.** The recurring failure here goes like this. A session
writes a new canonical module, moves the two easiest consumers, and stops. The header claims the job is done, and
the next session writes a third version. You must not be that session.

- The only new files you may create are the ones your spine's workstreams name in the plan, plus their specs and
  `scripts/check-*.py`. Anything else is an escalation.
- **A migration is finished or it is not started.** A workstream ends with every consumer moved, the old path
  **deleted**, and every header that mentions it true. If a consumer cannot move, do one of two things: revert the
  workstream so nothing is left half-converted, or narrow the foundation's header so it names the exception and
  why. Then escalate. Never leave two live mechanisms for one job behind a header that claims there is one.
- **Rewrite detector.** After each commit, run `git diff --stat HEAD~1`. If an existing file lost more than about
  60% of its lines and gained a similar amount, you rewrote it instead of moving things out of it. Revert and redo it
  as moves.

**2. A foundation assembles existing parts. It does not replace them.** `Schema` sits on `Sanitize`. `Endpoint`
composes `NetworkBridge`, `RateLimiter`, `RemoteHandler` and `AdminGate`. `PlayerState` uses `ChangeNotifier`.
`ServerTick` keeps `CombatTick`'s PHASES. Read the parts' headers and keep every guarantee they document.

**3. Behaviour, wire and storage are frozen.**
- Behaviour: preserve every observable answer bit-for-bit, including answers that look wrong. Write those down and
  escalate them. The combat feel skeleton (every timing, window, rewind cap and cooldown) is untouchable.
- Wire: every remote name and payload shape stays identical, and so does reliable versus unreliable. `PlayerState`
  carries a player's **state**; events (hits, swings, cues, realm messages) stay where they are.
- Storage: every DataStore key, persisted field name, `AuthoredContentStore` field and `SchemaVersion` stays
  identical. A foundation that cannot express an existing shape gets a documented escape hatch. The shape never
  changes to fit the foundation.

**4. Prove equivalence, don't assert it.** Every conversion of a decoder, codec, gate or registry lands with a spec
that runs the **old and new code on the same corpus** and asserts identical output. The corpus covers valid input,
each single-field corruption, `nil`, NaN, ±inf, and oversize strings. The old code may live in the spec as a frozen
copy until the conversion commit deletes it from `src`.

**5. One concern per commit, and renames never ride along with structure.**

## Authority (edit before pasting)

- Work on branch `cohesion/coworking-systems`. If you are in a worktree for a parallel spine, use your own branch,
  named `cohesion/<spine-slug>`, cut from `cohesion/coworking-systems`. Commit locally, one workstream step per
  commit, with a message that says what moved and what was deleted. End every commit message with
  `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`. **Do not push. Do not open a PR. Do not merge
  branches.**
- You may run the gates and the TestEZ suite. **Never run `run-in-roblox` while Roblox Studio is open.** Check with
  `tasklist | findstr RobloxStudio`. If it is open, ask the user to close it, or skip the suite and say so plainly.
- You may edit `test.project.json` for a new top-level folder. Keep `default.project.json` and `live.project.json` in
  sync, and run `check-live-project.py` after touching either. Do not touch place files, live DataStore data or
  `Server/Combat/AuthoredMoves/`.
- `CLAUDE.md` and `docs/software-architecture.md` are **append-only** for every spine except Spine 9.
- When you hit an escalation, write it down (format below) and **move on to the next independent step**. Do not stop
  the whole spine for one decision unless every remaining step depends on it.

## Toolchain (CLAUDE.md has the details; these are the traps)

- Strip the BOM from `ParkourConstants.lua` **in the same command as every build**. A BOM silently zeroes the suite:
  ```
  python -c "p='src/ReplicatedStorage/Shared/Parkour/ParkourConstants.lua'; d=open(p,'rb').read(); open(p,'wb').write(d[3:]) if d.startswith(b'\xef\xbb\xbf') else None"
  ```
- Suite: `rojo build test.project.json -o <scratchpad>/test.rbxl`, then
  `run-in-roblox --place <that> --script scripts/run-tests.lua`. A run takes about 90 s. **The printed tree truncates
  after `Combat`.** Read failures from the `TestService:` blocks, and never pipe the output through `tail`. If port
  50312 is held by a hung `run-in-roblox`, ask before killing it.
- Gates, run after every workstream: `selene src/` (0 errors; the 2 known `UDim2.fromScale` warnings),
  `stylua --check` on **touched files only** (the checkout is CRLF, so compare with CR ignored),
  `python scripts/check-logger-scopes.py`, `check-live-project.py`, `check-single-writers.py`,
  `check-spec-literals.py`, `check-stale-refs.py`, plus every check an earlier spine added (read the plan's Status).
  A new `Logger.scope` name needs a `DebugConstants` entry, or `check-logger-scopes` fails.
- Baseline: **3538 passed / 7 failed** after W1 (feint ×2, TrainingBot ×5, all pre-existing). **Re-measure it at the
  start of your session** and use your own number. A workstream is done only if the failure set is unchanged, or
  smaller on purpose with the reason stated.
- A new top-level folder under `Server/` or `Client/` (for example `Server/Data`, `Server/Content`, `Client/Vessel`)
  needs a `test.project.json` entry, or its broken requires surface only in Studio.
- No gate checks Roblox property names. Before writing an Instance property not already used in this repo, verify it
  in an existing file or a spec. The `Instance.new("Player")` harness limit is in the memory notes: player-keyed
  code needs an identity seam to be testable.

## Escalation format

Put each escalation in the plan doc's `## Escalations` section, numbered after the last one there, and in your final
report:

```
### E<n>. <one-line title>  (W<k>)
Found: <what the code does today, file:line>
Option A: <change> — consequence: <what a player/dev would notice>; effort: <S/M/L>
Option B: <keep>   — consequence: ...
Blocks: <what in this programme waits on it, or "nothing">
```

## What you report at the end

Write the report into the plan doc as a new `## Status (<spine>, <date>)` section, after the earlier ones, then
summarise it in chat:

1. Per workstream: done / partially reverted / not started, with the commits (hash + subject).
2. Every W21 ratchet your spine moved, as **measured** before → after.
3. Suite: baseline vs final pass/fail, with the failing spec names. Gates: each one's result.
4. Every file created and every file deleted.
5. Escalations.
6. **Not verified.** List everything a test cannot prove, each with a concrete playtest step. Anything in Spines 3,
   5, 6 or 7 that a player sees is "suite-green, needs playtest", never "working".
7. Every header comment you corrected because it was false, with the false claim quoted.

Mark the evidence for each claim: "read from source", "ran", or "inferred". Never call a module wired until you have
counted its non-spec inbound requires (CLAUDE.md, "Before claiming something is wired").

## Appendix: duplicate-body detector (part of `scripts/cohesion-report.py` in W21)

```python
import os, re, sys, hashlib, collections
root = sys.argv[1] if len(sys.argv) > 1 else "src"
bodies = collections.defaultdict(list)
for dp, _, fs in os.walk(root):
    if "Tests" in dp:
        continue
    for f in fs:
        if not f.endswith(".lua"):
            continue
        p = os.path.join(dp, f)
        lines = open(p, encoding="utf-8", errors="ignore").read().split("\n")
        for i, l in enumerate(lines):
            m = re.match(r"^(local\s+function|function)\s+([\w\.:]+)\s*\(", l)
            if not m:
                continue
            body = []
            for j in range(i + 1, min(i + 400, len(lines))):
                if lines[j].rstrip("\r") == "end":
                    break
                body.append(lines[j].strip())
            else:
                continue
            norm = [b for b in body if b and not b.startswith("--")]
            if len(norm) < 6:
                continue
            h = hashlib.md5("\n".join(norm).encode()).hexdigest()
            bodies[h].append((os.path.relpath(p, root), m.group(2), len(norm)))
dupes = [v for v in bodies.values() if len({x[0] for x in v}) > 1]
for v in sorted(dupes, key=lambda v: -v[0][2] * len(v)):
    print(v[0][2], "lines x", len(v), ":", ", ".join(f"{a}:{b}" for a, b, _ in v))
print("TOTAL", len(dupes))
```

---

# Part B: kickoffs, one per session

Each kickoff is self-contained. Paste one into a fresh session. Every kickoff starts the same way:

> Read `docs/architecture/2026-10-25-coworking-systems-agent-prompt.md` Part A completely, and follow it as if it had
> been pasted here: the rules, the Authority block, the toolchain and the report format. Then read the plan it
> names. Check that Studio is closed, re-measure the suite baseline, and record it.

Then add the block for the spine.

### Spine 1: test harness (run this next)

> Scope: Spine 1 (W2, W3) only. Build `Tests/TestHelpers/Rig.lua` and `Tests/TestHelpers/CombatHarness.lua` as the
> plan describes. Migrate the 20 specs' private `makeDummy`/`makeRig`/`makeCharacter` and the 9 reset chains, one
> test folder per commit. `CombatHarness.Reset` must follow `CombatTick.PHASES` order and WeaponFixture's
> install-once rule (read the memory note on it). Add the spec-literal rule against new private rig builders. Delete
> or use `TestHelpers/Fixtures.lua`. The failure set must stay exactly the 7. If converting a spec changes which
> assertions run, stop and escalate. Also draft W20's CLAUDE.md section as an append. Report and stop.

### Spine 2: data contracts (after Spine 1)

> Scope: Spine 2 (W4, W5, W6), strictly in that order. Stop at the end of any workstream whose equivalence specs you
> cannot make pass. W4: build `Shared/Schema.lua` on `Sanitize`. Convert SettingsSystem, then MoveRecordCodec, then
> the Kit/Race/Bloodline validators, each with an old-vs-new corpus spec. W5: **before moving anything**, commit a
> frozen corpus of real-shaped v1..vN profile records and a round-trip spec asserting byte-identical
> `EncodeProfile` output. Then move one slice per commit into its domain through `ProfileSlice`, with migrations
> still one ordered chain. W6: `Server/Network/Endpoint.lua`, then convert Systems in the plan's order. Delete
> BootManifest's hand remote lists only when every System is converted. Add `check-endpoints.py`. Report the
> `typeof` and NaN ratchets before and after.

### Spine 3: one replicated player state (after Spine 2's W4)

> Scope: Spine 3 (W7, W8). First commit the slice table (cadence, size, pull path for each of the ~10 slices in plan
> §1.7). Then build `PlayerState` and `ClientState.Observe`. Convert one slice per commit, with the old remote
> **still firing in parallel** until that slice's client side reads `ClientState`. Then delete the old remote and
> its manifest entry. Keep the `CultivationTier` Player Attribute. Move the private mirrors (CharacterMenuClient,
> InventoryClient, WeaponInventoryClient, BountyTab) onto ClientState, and correct ClientState's header. Add
> `check-player-state.py`. Everything here needs a playtest: write the checklist from the plan into your report.

### Spine 4: body restraint (parallel with Spines 2 and 6)

> Scope: Spine 4 (W9). Commit the full verb × restraint matrix (a `file:line` per cell, each blank marked deliberate
> or unexplained) into the plan **before** any code. Then build `Shared/Combat/BodyRestraint.lua` (Attributes only,
> no System requires) with one policy table. Migrate one consumer per commit, preserving every answer, and
> `bodyGate`'s refusal order and reason strings exactly. Leave the record-backed `CanAttack` gates alone. Each
> unexplained gap becomes an escalation, never a fix. Add the gate that fails on new direct restraint reads.

### Spine 5: frame, camera, pose, animation (last of the client spines)

> Scope: Spine 5 (W10, W11). W10: `Client/FrameOrder.lua` with a "reads what X wrote" line per slot, and no two
> slots sharing a value. Keep today's relative order wherever you cannot prove a dependency, and mark those
> entries "(order unverified: playtest)". Then `ServerTick` with Movement / Combat / World groups, preserving
> today's connection order exactly. W11: CameraRig only if it removes the flag peepholes with no behaviour change,
> otherwise escalate. Then TransformLayer absolute claims. Then the AnimationManager spike: commit its decision
> before any migration, one animator per commit, and revert any animator that loses the
> beat-the-default-Animate-script behaviour. Re-read the memories on Core priority, `toolnone` and replicated
> one-shots first. Report the full playtest checklist.

### Spine 6: input and settings (parallel with Spines 2 and 4)

> Scope: Spine 6 (W12, W13, W14). Add the missing router layers, then move each raw `UserInputService` dispatch
> onto `InputRouter`, one module per commit. UI gestures (text focus, drag, scrub) stay raw and are listed as
> exemptions in the router header. Continuous axes go through `Analog` + `KeybindManager`. Flight's hard-coded keys
> are escalation E1. Do the router plumbing that both options need, and leave the flight binding unchanged unless
> E1 has been answered in the plan. W13: one `DebugKeys` table with a clash check. W14: `SettingsStore.Observe`.
> Consumers subscribe, and SettingsClient stops requiring them. Read the memories on `IsKeyDown` and the
> ProximityPrompt Interact key first.

### Spine 7: vehicles (after Spine 6's W12)

> Scope: Spine 7 (W15). `Server/Vessel/VesselMountRegistry.lua` plus a shared `Client/Vessel/` helper (add it to
> `test.project.json`). Diff the pairs function by function first. A difference becomes config or a callback,
> never a per-vehicle flag. Vehicle input goes on the `Vehicle` router layer. Done when each pair shares under 40
> code lines outside the drive integrator and the mode machine. Read the memories on cloned tags and tagged
> templates first.

### Spine 8: content, lifecycle, boot, Highlights (after Spine 2)

> Scope: Spine 8 (W16-W19). W16: commit the layer model per content kind before code. Then `ContentRegistry` for
> moves, then races and bloodlines. Persistence and DataStore keys are untouched. W17: `Shared/PlayerScoped.lua`,
> one System per commit. Keep a leave handler that does more than clear tables. W18: `ClientBootManifest` with
> today's exact order, plus its spec. W19: a Highlight lease through `FXPool`.

### Spine 9: guardrails (last)

> Scope: Spine 9 (W20, W21). Finalise CLAUDE.md's "Extend, migrate, never fork" section, and add a row to
> CLAUDE.md's shared-module table for each foundation that has actually landed (check the Status sections and the
> inbound requires; never list one that hasn't). Write `scripts/cohesion-report.py` with every ratchet in plan
> W21, each with a ceiling set to the measured value today, plus `check-orphans.py` and the header-claims check.
> Re-measure the whole ratchet table and write the final numbers into the plan.
