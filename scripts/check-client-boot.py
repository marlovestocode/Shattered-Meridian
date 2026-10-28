#!/usr/bin/env python3
"""Holds the client's boot to account (coworking plan W18).

Client/Config/ClientBootManifest.lua declares two lists: BOOTED (started by Main.client.lua's boot helper) and STARTED_BY (started
by another module's own Start). This fails when:
  * a client module defines `function X.Start(` and is in neither list -- a Start nobody calls is a feature that never runs;
  * a BOOTED name is not booted by Main.client.lua, or Main boots a name BOOTED does not list;
  * a STARTED_BY owner's file never calls `X.Start`.

Run: python scripts/check-client-boot.py
"""
import os
import re
import sys

CLIENT = os.path.join("src", "StarterPlayer", "StarterPlayerScripts", "Client")
manifest = open(os.path.join(CLIENT, "Config", "ClientBootManifest.lua"), encoding="utf-8").read()
main = open(os.path.join(CLIENT, "Main.client.lua"), encoding="utf-8").read()

booted_block = re.search(r"ClientBootManifest\.Booted = table\.freeze\(\{(.*?)\}\)", manifest, re.S).group(1)
declared_booted = set(re.findall(r'"(\w+)"', booted_block))
started_block = re.search(r"ClientBootManifest\.StartedBy = table\.freeze\(\{(.*?)\}\)", manifest, re.S).group(1)
started_by = dict(re.findall(r'(\w+) = "(\w+)"', started_block))
main_booted = set(re.findall(r'\bboot\(\s*"(\w+)"', main))

# Module name -> every file with that name (two folders may share one: Client/DevTools and UI/Screens/DevTools are both "DevTools").
files = {}
for root, _, names in os.walk(CLIENT):
    for name in names:
        if name.endswith(".lua"):
            path = os.path.join(root, name)
            module = os.path.basename(root) if name == "init.lua" else name[: -len(".lua")]
            files.setdefault(module, []).append(path)

START = re.compile(r"^function \w+\.Start\(", re.M)

problems = []
for module, paths in sorted(files.items()):
    for path in paths:
        text = open(path, encoding="utf-8", errors="ignore").read()
        if START.search(text) and module not in declared_booted and module not in started_by:
            problems.append(f"{path}: defines Start but is in neither ClientBootManifest.Booted nor StartedBy")
for name in sorted(declared_booted - main_booted):
    problems.append(f"ClientBootManifest.Booted lists {name}, but Main.client.lua never boots it")
for name in sorted(main_booted - declared_booted):
    problems.append(f"Main.client.lua boots {name}, but ClientBootManifest.Booted does not list it")
for module, owner in sorted(started_by.items()):
    owner_paths = files.get(owner)
    if not owner_paths:
        problems.append(f"ClientBootManifest.StartedBy: {module}'s owner {owner} is not a client module")
        continue
    calls = re.compile(r"\b" + re.escape(module) + r"\.Start\(")
    if not any(calls.search(open(path, encoding="utf-8").read()) for path in owner_paths):
        problems.append(f"ClientBootManifest.StartedBy says {owner} starts {module}, but no {owner} module calls {module}.Start")

if problems:
    print("\n".join(problems))
    sys.exit(1)
print(f"check-client-boot: {len(declared_booted)} booted by Main, {len(started_by)} started by an owner, all accounted for")
