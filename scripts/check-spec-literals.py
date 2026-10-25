#!/usr/bin/env python3
"""Fails if a spec pastes a real Roblox asset id instead of reading it from the module that owns it.

Why: a pasted baseline clip id turned 13 cases red the day the clip was re-authored (2026-10-25 cohesion audit,
A8). Resolve it instead: `AttackAnimations.Get(moveId)`, a WeaponFixture slot, a constant. A made-up test id
(short, like rbxassetid://111111) is fine -- only 8+ digit ids, which look like real assets, are refused.

The ALLOWED list is the ids that predate this check and are not derivable (a sound used only as a stand-in
payload). Shrinking it is welcome; growing it needs a reason in the commit.

Run: python scripts/check-spec-literals.py
"""
import os
import re
import sys

ALLOWED = {
    ("src/Tests/FX/MovePresentation.spec.lua", "rbxassetid://9118823101"),
    ("src/Tests/FX/SoundManager.spec.lua", "rbxassetid://76038309546970"),
    ("src/Tests/MoveEditor/MovePresentation.spec.lua", "rbxassetid://9118823101"),
    ("src/Tests/Loading/AssetPreloader.spec.lua", "rbxassetid://70000001"),
    ("src/Tests/Loading/AssetPreloader.spec.lua", "rbxassetid://70000002"),
}
PATTERN = re.compile(r"rbxassetid://(\d{8,})")

problems = []
for root, _, files in os.walk(os.path.join("src", "Tests")):
    for name in files:
        if not name.endswith(".lua"):
            continue
        path = os.path.join(root, name).replace(os.sep, "/")
        text = open(path, encoding="utf-8", errors="ignore").read()
        for lineno, line in enumerate(text.split("\n"), 1):
            for match in PATTERN.finditer(line):
                full = match.group(0)
                if (path, full) not in ALLOWED:
                    problems.append(f"{path}:{lineno}: pasted asset id {full}")

if problems:
    print("check-spec-literals: resolve these from the owning module instead of pasting them:")
    for p in problems:
        print("  " + p)
    sys.exit(1)
print("check-spec-literals: ok")
