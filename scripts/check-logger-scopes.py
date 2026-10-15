#!/usr/bin/env python3
"""Lists every Logger.scope("Name") in src/ that is missing from DebugConstants.Debug.Logging.Scopes.

The Scopes table is an ALLOWLIST: a scope not in it prints nothing, errors and warnings included, so a new
System that forgets its entry fails silently (CombatTick did -- a phase that threw every frame left no line
anywhere). Run this after adding a Logger.scope and add whatever it prints to that table.

    python scripts/check-logger-scopes.py        # exit 1 and a list when something is missing, else 0
"""

import os
import re
import sys
from collections import defaultdict

DEBUG_CONSTANTS = "src/ReplicatedStorage/Shared/DebugConstants.lua"
SCOPE_CALL = re.compile(r"Logger\.scope\(\s*[\"']([A-Za-z_][A-Za-z0-9_]*)[\"']\s*\)")
ENTRY = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?:true|false)", re.M)


def used_scopes() -> dict:
    used = defaultdict(list)
    for root, _, files in os.walk("src"):
        norm = root.replace(os.sep, "/")
        if "/Tests" in norm or norm.endswith("Tests"):
            continue
        for name in files:
            if not name.endswith(".lua"):
                continue
            path = os.path.join(root, name).replace(os.sep, "/")
            with open(path, encoding="utf-8-sig", errors="ignore") as handle:
                for match in SCOPE_CALL.finditer(handle.read()):
                    used[match.group(1)].append(path)
    return used


def listed_scopes() -> set:
    with open(DEBUG_CONSTANTS, encoding="utf-8-sig") as handle:
        text = handle.read()
    start = text.index("Scopes = {")
    opening = text.index("{", start)
    depth = 0
    for index in range(opening, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return set(ENTRY.findall(text[opening:index]))
    raise SystemExit("could not find the end of the Scopes table")


def main() -> int:
    used = used_scopes()
    missing = sorted(set(used) - listed_scopes())
    if not missing:
        print(f"ok: all {len(used)} logger scopes are in DebugConstants.Debug.Logging.Scopes")
        return 0
    print(f"{len(missing)} logger scope(s) missing from DebugConstants.Debug.Logging.Scopes:")
    for name in missing:
        print(f"  {name} = true,    -- {used[name][0]}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
