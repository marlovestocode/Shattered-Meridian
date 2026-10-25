#!/usr/bin/env python3
"""Fails if a spec pastes a real Roblox asset id instead of reading it from the module that owns it, or
builds its own rig instead of using Tests/TestHelpers/Rig.lua.

Why: a pasted baseline clip id turned 13 cases red the day the clip was re-authored (2026-10-25 cohesion audit,
A8). Resolve it instead: `AttackAnimations.Get(moveId)`, a WeaponFixture slot, a constant. A made-up test id
(short, like rbxassetid://111111) is fine -- only 8+ digit ids, which look like real assets, are refused.

The ALLOWED list is the ids that predate this check and are not derivable (a sound used only as a stand-in
payload). Shrinking it is welcome; growing it needs a reason in the commit.

Rigs (2026-10-25, W2-W3): twenty-two specs each defined their own makeDummy / makeRig / makeCharacter, and the
cohesion audit traced 34 of 43 red tests to fixture drift between them. A spec now builds a body with
`Rig.Dummy`/`Rig.Character`/`Rig.R6`/`Rig.Limbs`/`Rig.Bare` and registers it with `CombatHarness.Combatant` or
`CombatHarness.Spawner`. Two rules, both skipping Tests/TestHelpers: no `local function make<Dummy|Rig|Character|R6|
Opponent>` (or `local make... =`) in a spec, and no spec that sets a `HumanoidRootPart` Name AND instances a
Humanoid in the same file (the shape of a hand-built rig whatever the builder is called). A body that is
deliberately not a rig -- a bare Model a module keys by, a hurtbox-gather fixture -- is fine: it has no Humanoid.

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
BUILDER = re.compile(r"^\s*local\s+(?:function\s+)?make(?:Dummy|Rig|Character|R6|Opponent)\w*")
ROOT_NAME = re.compile(r'\.Name\s*=\s*"HumanoidRootPart"')
NEW_HUMANOID = re.compile(r'Instance\.new\("Humanoid"\)')

problems = []
for root, _, files in os.walk(os.path.join("src", "Tests")):
    for name in files:
        if not name.endswith(".lua"):
            continue
        path = os.path.join(root, name).replace(os.sep, "/")
        text = open(path, encoding="utf-8", errors="ignore").read()
        helper = "/TestHelpers/" in path
        for lineno, line in enumerate(text.split("\n"), 1):
            for match in PATTERN.finditer(line):
                full = match.group(0)
                if (path, full) not in ALLOWED:
                    problems.append(f"{path}:{lineno}: pasted asset id {full}")
            if not helper and BUILDER.match(line):
                problems.append(f"{path}:{lineno}: private rig builder -- use Tests/TestHelpers/Rig.lua or CombatHarness.lua")
        if not helper and ROOT_NAME.search(text) and NEW_HUMANOID.search(text):
            problems.append(f"{path}: hand-built rig (a HumanoidRootPart and a Humanoid made in the spec) -- use Rig.lua")

if problems:
    print("check-spec-literals: resolve asset ids from the owning module, and build rigs through TestHelpers/Rig.lua:")
    for p in problems:
        print("  " + p)
    sys.exit(1)
print("check-spec-literals: ok")
