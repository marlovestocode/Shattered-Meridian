# Agent prompt: make the systems cowork (for Sonnet 5.5)

Paste everything below the line into a fresh Claude Code session running Sonnet 5.5, with this repository open.
Before pasting, edit the **Authority** block if you want different commit or scope rules.

---

You are working in **Shattered Meridian**, a Roblox Luau project (Rojo, TestEZ, selene, stylua). This is a
**cohesion pass**. Your job is to make the existing systems work through shared owners instead of each system
re-deriving the same answer, and to **finish migrations that earlier sessions started and abandoned**. It is not
feature work, and it is not a rewrite.

## Read first, in this order

1. `CLAUDE.md`, all of it. It outranks this prompt wherever the two disagree. Say so when that happens.
2. `docs/architecture/2026-10-25-coworking-systems-plan.md`. **This is your plan.** Workstreams W0-W6, with evidence.
3. `docs/architecture/2026-10-25-cohesion-audit.md` (gates, the suite baseline, the maintenance rules) and
   `docs/architecture/2026-10-25-codebase-audit.md` (what is already fixed, so you don't redo it).
4. `docs/software-architecture.md` and `docs/luau-coding-standards.md`.
5. Before touching a module, read **its whole header comment**. Headers here are long and load-bearing, and they
   record why things are the shape they are. They are also sometimes **false**: the plan documents
   `AnimationManager`'s. Verify every header claim you depend on against the code.
6. If the `shattered-meridian-studio` skill is available, invoke it once at the start.

## The one rule this pass exists to enforce

**Extend and migrate. Never fork, and never rebuild.**

This codebase has a recurring failure. A session writes a new canonical module next to the old ones and moves the
two easiest consumers. Then it stops. The header claims the job is done. The next session finds two systems for
one job and writes a third. You must not be that session. Concretely:

- **Before you create any file**, search for an existing owner: the plan's §1.1, CLAUDE.md's table, and
  `grep -rn "Owns:" src/`. The only new files you may create are the ones the plan names (`VesselMountRegistry`, a
  `Client/Vessel` helper, `BodyRestraint`, `FrameOrder`, `LocalAnimator` if W5 chooses (a), and the new
  `scripts/check-*.py`). Anything else is an escalation.
- **A migration is finished or it is not started.** Each workstream ends with every consumer moved, the old path
  **deleted**, and every header that mentions it true. If you discover partway through that a consumer cannot move,
  stop that workstream. Then choose one: revert it so nothing is left half-converted, or narrow the new owner's
  header so it names the exception and gives the reason. Then escalate. Never leave the tree with two live
  mechanisms for one job and a header saying there is one.
- **Preserve behaviour bit-for-bit.** This is refactoring. If the old code gave an answer that looks wrong (a
  restraint gap, an odd frame order), keep that answer, write it down, and escalate it. Do not "fix it while you're
  there". The combat feel skeleton (every timing, window, rewind cap and cooldown) is frozen.
- **Rewrite detector.** After each step, run `git diff --stat`. If a step deletes more than about 60% of an existing
  file and re-adds similar volume, you are rewriting, not migrating. Stop, revert that file, and do it as moves.
- **Never mix a rename with a behaviour or structure change** in one commit.

## Authority (edit before pasting)

- Work on a new branch `cohesion/coworking-systems`, cut from the current branch. Commit locally, **one concern per
  commit** (one workstream step = one commit), with a message that says what moved and what was deleted. End every
  commit message with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`. **Do not push. Do not open a PR.**
- You may run the gates and the TestEZ suite. **Never run `run-in-roblox` while Roblox Studio is open.** Check
  first (`tasklist | findstr RobloxStudio`). If it is open, ask the user to close it, or skip the suite and say so.
- You may not edit `live.project.json`/`default.project.json` except to keep them in sync. You may edit
  `test.project.json` for a new top-level folder. You may not touch place files, DataStore code paths, or anything
  under `AuthoredMoves/`.
- When you hit an escalation, write it down (format below) and **move on to the next independent step**. Do not
  stop the whole pass for one decision.

## Toolchain (CLAUDE.md has the details; these are the traps)

- Strip the BOM from `ParkourConstants.lua` **in the same command as every build**. A BOM silently zeroes the suite:
  ```
  python -c "p='src/ReplicatedStorage/Shared/Parkour/ParkourConstants.lua'; d=open(p,'rb').read(); open(p,'wb').write(d[3:]) if d.startswith(b'\xef\xbb\xbf') else None"
  ```
- Suite: `rojo build test.project.json -o <scratchpad>/test.rbxl`, then
  `run-in-roblox --place <that> --script scripts/run-tests.lua`. A run takes about 90 s. **The printed tree truncates
  after `Combat`.** Read failures from the `TestService:` blocks, and never pipe the output through `tail`. If port
  50312 is held by a hung `run-in-roblox`, ask before killing it.
- Gates, run after every workstream: `selene src/` (0 errors; 2 known `UDim2.fromScale` warnings),
  `stylua --check` **on the files you touched only** (the checkout is CRLF), `python scripts/check-logger-scopes.py`,
  `check-live-project.py`, `check-single-writers.py`, `check-spec-literals.py`, `check-stale-refs.py`, plus every
  new check you add.
- Baseline: last measured as **3538 passed / 7 failed** (feint ×2, TrainingBot ×5, all pre-existing). **Measure it
  yourself in W0** and use your number. A workstream is done only if the failure set is unchanged, or smaller on
  purpose with the reason stated.
- A new top-level folder under `Server/` or `Client/` needs a `test.project.json` entry, or its broken requires
  surface only in Studio.
- Roblox property names are not checked by any gate. If you write an Instance property you have not seen used
  elsewhere in this repo, verify the name in an existing file or a spec.

## Execution order

Follow the plan's §3. **W0 first, always.** Then W1 → W2 → W3 → W4, which touch disjoint files. Then W5, then
finish W6. W6's CLAUDE.md rule and ownership-map section may be drafted during W0. Append to `CLAUDE.md` and
`docs/software-architecture.md`; never restructure them.

Per-workstream notes that the plan does not spell out:

- **W0.** Re-run every §1 count and correct the plan doc in place where reality has moved. The appendix script
  reproduces the duplicate-body count. Build the ownership map from what the code does, not from what headers say.
- **W1.** Keep every `OnX` signature and return type identical. Grep the specs for each module's reset function
  and wire `:Clear()` into it.
- **W2.** Diff the two Systems function by function before extracting. A body that differs by 2-7 lines becomes
  one function taking a config field or callback. **Do not** add a flag per vehicle. If a difference cannot be
  expressed as config, leave that function vehicle-specific and say why.
- **W3.** The matrix comes **before** any code, with a `file:line` per cell, committed into the plan doc as its own
  commit. Then write `BodyRestraint`, then migrate one consumer per commit, running that consumer's specs each
  time. `AttackRequestSystem.bodyGate` must keep its refusal **order** and **reason strings**, because clients and
  `AttackConstants.Input.TransientRefusals` key on them. `BodyRestraint` may not require any System; it reads
  Attributes through `AttributeConstants` only.
- **W4.** For each slot shared by several modules, write a short "X reads what Y wrote, so X goes after Y" line,
  or "independent". Only then assign values. If you cannot establish a dependency from source, keep the modules'
  current relative registration order and mark the entry `(order unverified: playtest)`.
- **W5.** The spike's decision, (a) or (b) per animator, is written down and committed before any migration code.
  Re-read the memories that CLAUDE.md and `docs/animation-systems.md` point to on Core priority, the `toolnone`
  pose, and replicated one-shots. Each animator is one commit. If a migrated animator loses the
  beat-the-default-Animate-script behaviour, that is a regression: revert it and take branch (b) for that animator.

## Escalation format

Put each escalation in a section `## Escalations` at the end of the plan doc, and in your final report:

```
### E<n>. <one-line title>  (W<k>)
Found: <what the code does today, file:line>
Option A: <change> — consequence: <what a player/dev would notice>; effort: <S/M/L>
Option B: <keep>   — consequence: ...
Blocks: <what in this pass waits on it, or "nothing">
```

## What you report at the end

Write the report into the plan doc, under a `## Status (pass of <date>)` section, then summarise it in chat:

1. Per workstream: done / partially reverted / not started, the commits (hash + subject), and the §4 "Done means"
   row before → after, as **measured** numbers.
2. Suite: baseline vs final pass/fail, with the failing spec names. Gates: each one's result.
3. Every file created and every file deleted.
4. Escalations.
5. **Not verified.** List everything a test cannot prove: camera order, animation ownership, pose stacking on a
   mounted pilot. Give each one a concrete playtest step. Do not call anything in W4 or W5 "working"; call it
   "suite-green, needs playtest".
6. Every header comment you corrected because it was false, with the false claim quoted.

Be precise about evidence. Say "read from source", "ran", or "inferred" for each claim. Do not describe a feature as
wired until you have checked its inbound requires (CLAUDE.md, "Before claiming something is wired").

## Appendix: duplicate-body detector (becomes `scripts/check-duplicate-bodies.py` in W6)

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

As a gate, it compares `TOTAL` against a ceiling stored in the script (the count after W1/W2) and fails if `TOTAL`
goes above it. It is a ratchet, the same as `check-stale-refs.py`.
