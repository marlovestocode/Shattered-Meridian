#!/usr/bin/env python3
"""Fails if an Attribute that has ONE owner is written anywhere else.

An Attribute is an untyped seam between modules that do not require each other, so the only enforceable
statement of "who may write it" is a scan. Each entry below is a rule that was learned the hard way:

  RootControlLocked  five writers; the first release unlocked a body another still held (RootControl.lua).
  KnockbackUntil     four bare writers; a shorter stamp overwrote a longer launch allowance (MovementAllowance.lua).
  HitstunUntil       one file owns the "extend, never shorten" rule and its one deliberate shortening (a stun
                     parry's exit), so every write sits beside both (DamageSystem.lua).

A WRITE is any call to SetAttribute / setAttribute / extendDeadline whose argument list names the attribute --
across line breaks (stylua wraps long calls), and through a local helper that forwards the name. Comments and
string-free reads (GetAttribute, GetAttributeChangedSignal) are not writes. A new owner is a new row.

The same rule for the two client Humanoid switches that are claim gates (Client/Movement), matched as a
property write or a state call rather than an Attribute name:

  AutoRotate         four snapshot/restore writers undid each other's holds (TurnGate.lua).
  Jumping state      three writers handed the jump back while another still held it (JumpGate.lua).

Run: python scripts/check-single-writers.py
"""
import os
import re
import sys

# attribute name -> the files (by basename) allowed to write it
OWNERS = {
    "RootControlLocked": {"RootControl.lua"},
    "KnockbackUntil": {"MovementAllowance.lua"},
    "HitstunUntil": {"DamageSystem.lua"},
    # The ragdoll's three: DamageSystem reads them (RagdollRules.Admits) to decide a hit before OnApplied, so a
    # second writer would make that decision disagree with the body.
    "Ragdolled": {"RagdollSystem.lua"},
    "RagdollChainEndsAt": {"RagdollSystem.lua"},
    "RagdollImmuneUntil": {"RagdollSystem.lua"},
}

# client switch -> (pattern of a write, the file allowed to make it). Only StarterPlayer is scanned: the
# server's own writes (AdminActionSystem's flight, a training bot's body) are a different Humanoid's owner.
CLIENT_SWITCHES = {
    "AutoRotate": (re.compile(r"\.AutoRotate\s*=(?!=)"), "TurnGate.lua"),
    "Jumping state": (
        re.compile(r"SetStateEnabled\s*\(\s*Enum\.HumanoidStateType\.Jumping\b"),
        "JumpGate.lua",
    ),
}

WRITER = re.compile(r"\b(?:SetAttribute|setAttribute|extendDeadline)\s*\(")


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


def call_arguments(text: str, open_paren: int) -> str:
    """The text between the parenthesis at `open_paren` and its match."""
    depth = 0
    for j in range(open_paren, len(text)):
        if text[j] == "(":
            depth += 1
        elif text[j] == ")":
            depth -= 1
            if depth == 0:
                return text[open_paren + 1 : j]
    return text[open_paren + 1 :]


def top_level_arguments(args: str) -> list:
    """`args` split on the commas that are not inside a nested call, table or string."""
    parts, depth, current, quote = [], 0, [], None
    for ch in args:
        if quote:
            current.append(ch)
            if ch == quote:
                quote = None
            continue
        if ch in ('"', "'"):
            quote = ch
        elif ch in "({[":
            depth += 1
        elif ch in ")}]":
            depth -= 1
        elif ch == "," and depth == 0:
            parts.append("".join(current).strip())
            current = []
            continue
        current.append(ch)
    parts.append("".join(current).strip())
    return parts


def names_attribute(argument: str, attribute: str) -> bool:
    """True for `Attribute`, `Constants.Attribute`, `"Attribute"` -- the NAME being written, not a call that
    merely has the same word in it (`math.max(now, DamageSystem.HitstunUntil(model))`)."""
    dotted = re.fullmatch(r"(?:[A-Za-z_][A-Za-z0-9_]*[.])*" + attribute, argument) is not None
    return dotted or argument in ('"' + attribute + '"', "'" + attribute + "'")


problems = []
for root, _, files in os.walk("src"):
    if "Tests" in root.split(os.sep):
        continue
    for name in files:
        if not name.endswith(".lua") or name.endswith(".spec.lua"):
            continue
        path = os.path.join(root, name)
        text = strip_comments(open(path, encoding="utf-8", errors="ignore").read().replace("\r", ""))
        for match in WRITER.finditer(text):
            args = top_level_arguments(call_arguments(text, match.end() - 1))
            for attribute, owners in OWNERS.items():
                if name in owners:
                    continue
                if any(names_attribute(argument, attribute) for argument in args):
                    line = text.count("\n", 0, match.start()) + 1
                    problems.append(
                        f"{path.replace(os.sep, '/')}:{line}: writes {attribute} (owner: {', '.join(sorted(owners))})"
                    )
        if "StarterPlayer" in root.split(os.sep):
            for switch, (pattern, owner) in CLIENT_SWITCHES.items():
                if name == owner:
                    continue
                for match in pattern.finditer(text):
                    line = text.count("\n", 0, match.start()) + 1
                    problems.append(f"{path.replace(os.sep, '/')}:{line}: writes {switch} (owner: {owner})")

if problems:
    print("check-single-writers: an owned Attribute is written outside its owner:")
    for p in problems:
        print("  " + p)
    sys.exit(1)
print(f"check-single-writers: ok ({len(OWNERS)} owned attributes, {len(CLIENT_SWITCHES)} client switches)")
