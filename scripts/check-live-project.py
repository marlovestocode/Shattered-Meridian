#!/usr/bin/env python3
"""Assert live.project.json is default.project.json plus globIgnorePaths, and nothing else.

live.project.json exists to publish a place WITHOUT the dev-tooling subtrees (Client/DevTools and
UI/Screens/DevTools) -- roughly 18.5k lines of admin-only Luau every client would otherwise require,
parse and closure-build at boot for panels only a whitelisted admin can open.

Rojo has no project inheritance, so the two files necessarily carry the same `tree` twice. That is
the only real cost of the split, and it is a drift hazard: an edit to default.project.json's tree
(a new spawn, a new top-level folder) that is not mirrored into live.project.json produces a place
that builds cleanly and is silently missing something. This script is the guard -- run it alongside
selene/stylua, and after ANY edit to either project file.

Deliberately NOT a check that the ignore paths are correct; it only checks the two files agree
everywhere else. `rojo build live.project.json` plus a grep for a dev-tool module name is what
verifies the exclusion itself actually bites.
"""

import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DEFAULT = ROOT / "default.project.json"
LIVE = ROOT / "live.project.json"

# The one key live.project.json is allowed to add. Everything else must match default's exactly.
ALLOWED_EXTRA_KEYS = {"globIgnorePaths"}


def main() -> int:
    default = json.loads(DEFAULT.read_text(encoding="utf-8"))
    live = json.loads(LIVE.read_text(encoding="utf-8"))

    problems = []

    extra = set(live) - set(default)
    if extra - ALLOWED_EXTRA_KEYS:
        problems.append(f"live.project.json has unexpected extra keys: {sorted(extra - ALLOWED_EXTRA_KEYS)}")

    missing = set(default) - set(live)
    if missing:
        problems.append(f"live.project.json is missing keys present in default.project.json: {sorted(missing)}")

    for key in sorted(set(default) & set(live)):
        if default[key] != live[key]:
            problems.append(
                f"key {key!r} differs between the two project files -- "
                "live.project.json must match default.project.json everywhere except globIgnorePaths"
            )

    if not live.get("globIgnorePaths"):
        problems.append("live.project.json has no globIgnorePaths -- it would ship the dev tooling it exists to omit")

    if problems:
        for problem in problems:
            print(f"check-live-project: {problem}", file=sys.stderr)
        print(
            "\nFix: re-derive live.project.json from default.project.json, keeping its globIgnorePaths.",
            file=sys.stderr,
        )
        return 1

    print("check-live-project: live.project.json matches default.project.json (+ globIgnorePaths)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
