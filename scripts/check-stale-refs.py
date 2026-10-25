#!/usr/bin/env python3
"""A ratchet on references to modules that no longer exist.

`CombatSystem` was deleted when the combat stack was rebuilt as HitboxEngine -> Defense -> Damage -> Attack, but
comments across src/ still cite it as the owner of things (2026-10-25 cohesion audit, A4). Rewriting ~160
comments in one sweep is a change of its own, so this only stops the number GROWING: a new comment citing a
deleted module fails. Fix some, then lower BASELINE to the new count -- never raise it.

Run: python scripts/check-stale-refs.py
"""
import os
import re
import sys

# pattern -> the count that existed when the ratchet was set (non-spec files under src/, 2026-10-25)
BASELINES = {
    r"\bCombatSystem\b": 162,
}

counts = {pattern: 0 for pattern in BASELINES}
for root, _, files in os.walk("src"):
    if "Tests" in root.split(os.sep):
        continue
    for name in files:
        if not name.endswith(".lua") or name.endswith(".spec.lua"):
            continue
        text = open(os.path.join(root, name), encoding="utf-8", errors="ignore").read()
        for pattern in BASELINES:
            counts[pattern] += len(re.findall(pattern, text))

failed = False
for pattern, baseline in BASELINES.items():
    now = counts[pattern]
    if now > baseline:
        print(f"check-stale-refs: {pattern} appears {now} times, above the ratchet of {baseline}")
        failed = True
    elif now < baseline:
        print(f"check-stale-refs: {pattern} is down to {now}; lower BASELINES to {now} to keep the gain")
if failed:
    sys.exit(1)
print("check-stale-refs: ok")
