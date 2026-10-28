#!/usr/bin/env python3
"""Fails if server code puts a remote on the wire anywhere but Server/Network/Endpoint.lua.

Endpoint (coworking plan F2, W6) is the one place a remote is created, rate-limited, decoded, pcall-wrapped, logged and declared
to BootManifest. Before it, 73 handlers hand-assembled those parts, each slightly differently, and BootManifest kept a second,
hand-written copy of which System owned which remote. A bare handler or a bare create re-opens both gaps, so this scan fails on:

  OnServerEvent       any use outside Endpoint -- `:Connect`, a Trove's `:Connect(remote.OnServerEvent, ...)`, `:Once`
  OnServerInvoke =    assigning a RemoteFunction's handler
  NetworkBridge.Create*  creating a remote (a server -> client push is `endpoint.Push(name)`)

Resolving a remote another System owns (NetworkBridge.Get*) is not a create and is never flagged. Comments are ignored.

EXEMPTIONS are by file, each with the reason it cannot be expressed through Endpoint. A new one needs a reason, not a habit:

  ServerHopSystem.lua  its RequestTeleport answers `(boolean, string?)`, a multi-return Endpoint.Function's single result cannot
                       carry (Endpoint.lua's own header names it).

Run: python scripts/check-endpoints.py
"""
import os
import re
import sys

EXEMPT = {
    "Endpoint.lua": "the owner",
    "ServerHopSystem.lua": "multi-return (boolean, string?) RemoteFunction",
}

PATTERNS = [
    (re.compile(r"\bOnServerEvent\b"), "handles OnServerEvent directly"),
    (re.compile(r"\bOnServerInvoke\s*=(?!=)"), "assigns OnServerInvoke directly"),
    (re.compile(r"\bNetworkBridge\.Create\w*\s*\("), "creates a remote directly"),
]


def strip_comments(text: str) -> str:
    """Blank out comments, keeping every newline so offsets still map to line numbers."""
    out = []
    i = 0
    n = len(text)
    while i < n:
        if text.startswith("--[", i):
            m = re.match(r"--\[(=*)\[", text[i:])
            if m:
                close = "]" + m.group(1) + "]"
                end = text.find(close, i + len(m.group(0)))
                end = n if end == -1 else end + len(close)
                out.append(re.sub(r"[^\n]", " ", text[i:end]))
                i = end
                continue
        if text.startswith("--", i):
            end = text.find("\n", i)
            end = n if end == -1 else end
            out.append(" " * (end - i))
            i = end
            continue
        out.append(text[i])
        i += 1
    return "".join(out)


problems = []
for root, _, files in os.walk(os.path.join("src", "ServerScriptService")):
    if "Tests" in root.split(os.sep):
        continue
    for name in files:
        if not name.endswith(".lua") or name.endswith(".spec.lua") or name in EXEMPT:
            continue
        path = os.path.join(root, name)
        text = strip_comments(open(path, encoding="utf-8", errors="ignore").read().replace("\r", ""))
        for pattern, what in PATTERNS:
            for match in pattern.finditer(text):
                line = text.count("\n", 0, match.start()) + 1
                problems.append(f"{path.replace(os.sep, '/')}:{line}: {what} -- declare it through Server/Network/Endpoint")

if problems:
    print("\n".join(problems))
    print(f"\n{len(problems)} remote(s) outside Endpoint. See scripts/check-endpoints.py for the rule and its exemptions.")
    sys.exit(1)
print("check-endpoints: every server remote goes through Endpoint (exempt: " + ", ".join(sorted(EXEMPT)) + ")")
