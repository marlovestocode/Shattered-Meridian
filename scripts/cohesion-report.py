#!/usr/bin/env python3
"""The cohesion ratchet (coworking plan W21): one table of every measure of "one mechanism per job", each with a stored ceiling.

A measure that RISES above its ceiling fails the run. A measure that falls is reported; `--update` writes the new, lower numbers
into scripts/cohesion-ceilings.json -- run it after a change that improved one, and commit the file with that change. A ceiling is
never raised by hand: a rise is a new copy of something the codebase already has one of, and the fix is to use that one.

The existing single-purpose gates (check-endpoints, check-single-writers, check-spec-literals, check-stale-refs) stay as they are and
keep failing on their own rules; this report counts, it does not replace them.

Measures (each function below says exactly what it counts):
  typeof_server          `typeof(` in server code. Untrusted data is decoded by Shared/Schema, not by hand.
  nan_checks             `x ~= x` outside Sanitize/Schema. NaN is the decoder's job.
  bare_remote_handlers   OnServerEvent / OnServerInvoke / NetworkBridge.Create* in server code outside Endpoint (+ its exemptions).
  raw_input_files        client files outside Client/Input that connect UserInputService input signals or ContextActionService.
  shared_render_priority BindToRenderStep calls whose resolved priority another call also uses (counted per extra call).
  unscoped_player_tables `local x: { [Player]: ... } = {}` in server code -- a Player-keyed table that is not PlayerScoped.
  load_animation_bypass  `:LoadAnimation(` in client code outside AnimationManager / AnimatorUtil.
  spec_rig_builders      spec-private `local function make(Dummy|Rig|Character)`.
  duplicate_functions    top-level function bodies (>= 6 statements) that appear byte-identical (after whitespace/comments) in
                         more than one file; counted per extra copy.
  restraint_reads        direct reads of a restraint Attribute outside Shared/Combat/BodyRestraint (+ exemptions with reasons).
  settings_hub_requires  gameplay modules SettingsClient requires (W14: consumers subscribe to SettingsStore instead).
  vessel_shared_lines    lines Blimp and Boat (server System + client controller) share verbatim (W15).
  highlight_bypass       client Highlights created outside Client/FX/HighlightBudget (W19).
  stale_combatsystem     references to the deleted `CombatSystem`.

Run: python scripts/cohesion-report.py [--update]
"""
import hashlib
import json
import os
import re
import sys

ROOT = "src"
CEILINGS = os.path.join("scripts", "cohesion-ceilings.json")
SERVER = os.path.join("src", "ServerScriptService")
CLIENT = os.path.join("src", "StarterPlayer")


def strip_comments(text: str) -> str:
    out, i, n = [], 0, len(text)
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


def sources(under: str, specs: bool = False):
    for root, _, files in os.walk(under):
        in_tests = "Tests" in root.split(os.sep)
        for name in files:
            if not name.endswith(".lua"):
                continue
            is_spec = name.endswith(".spec.lua") or in_tests
            if is_spec != specs:
                continue
            path = os.path.join(root, name)
            raw = open(path, encoding="utf-8", errors="ignore").read().replace("\r", "")
            yield path, name, raw, strip_comments(raw)


def typeof_server():
    # Runtime checks only: `:: typeof(X)` / `& typeof(X)` are type annotations, not a hand-written decode.
    pattern = re.compile(r"(?<!::\s)(?<!&\s)\btypeof\(")
    return sum(len(pattern.findall(code)) for _, _, _, code in sources(SERVER))


def nan_checks():
    pattern = re.compile(r"\b([A-Za-z_][\w.]*)\s*~=\s*\1\b(?!\s*[.(\[])")
    total = 0
    for _, name, _, code in sources(ROOT):
        if name in ("Sanitize.lua", "Schema.lua"):
            continue
        total += len(pattern.findall(code))
    return total


def bare_remote_handlers():
    exempt = {"Endpoint.lua", "ServerHopSystem.lua"}
    pattern = re.compile(r"\bOnServerEvent\b|\bOnServerInvoke\s*=(?!=)|\bNetworkBridge\.Create\w*\s*\(")
    return sum(len(pattern.findall(code)) for _, name, _, code in sources(SERVER) if name not in exempt)


def raw_input_files():
    # Client files that dispatch raw input outside Client/Input. Exempt, by file, with the reason (UI gestures and capture are
    # not actions; the vehicles wait on a Vehicle router layer).
    exempt = {
        "Chrome.lua": "the one Escape owner (UI/Shell)",
        "SettingsClient.lua": "rebind capture listens to the raw next key by definition",
        "NumericField.lua": "slider drag / edit-field keys: a UI gesture",
        "TimelineBar.lua": "scrub drag: a UI gesture",
        "PlacementCamera.lua": "dev camera mouse look: a UI gesture",
        "HitboxWorldPreview.lua": "dev preview's CAS input sink",
        "EditorViewport.lua": "World Architect's in-world gestures (pick, gizmo cancel, brush drag) and CAS key sink",
        "EmoteWheelClient.lua": "radial wheel gesture (open, track, release, cancel)",
        "OnboardingClient.lua": "hold-to-continue gesture (key or pointer)",
        "MoveEditorClient.lua": "in-panel dev shortcuts while the editor is open",
        "BlimpController.lua": "vehicle controls with the ButtonA gameProcessed quirk -- waits on a Vehicle router layer (W12/W15)",
        "BoatController.lua": "vehicle controls with the ButtonA gameProcessed quirk -- waits on a Vehicle router layer (W12/W15)",
    }
    pattern = re.compile(
        r"UserInputService\.(InputBegan|InputEnded|InputChanged)\b|ContextActionService:Bind(Action|ActionAtPriority)\b"
    )
    input_dir = os.sep + os.path.join("Client", "Input") + os.sep
    return sum(
        1
        for path, name, _, code in sources(CLIENT)
        if input_dir not in path and name not in exempt and pattern.search(code)
    )


RENDER_ENUM = {"First": 0, "Input": 100, "Camera": 200, "Character": 300, "Last": 2000}


def resolve_priority(expr: str, code: str, depth: int = 0):
    expr = expr.strip()
    if depth > 4:
        return None
    if re.fullmatch(r"-?\d+", expr):
        return int(expr)
    m = re.fullmatch(r"Enum\.RenderPriority\.(\w+)\.Value\s*(?:([+-])\s*(\d+))?", expr)
    if m and m.group(1) in RENDER_ENUM:
        base = RENDER_ENUM[m.group(1)]
        if m.group(2):
            base += int(m.group(3)) * (1 if m.group(2) == "+" else -1)
        return base
    m = re.fullmatch(r"([A-Za-z_]\w*)", expr)
    if m:
        d = re.search(r"^local\s+" + re.escape(expr) + r"(?:\s*:\s*\w+)?\s*=\s*([^\n]+)$", code, re.M)
        if d:
            return resolve_priority(d.group(1), code, depth + 1)
    return None


def shared_render_priority():
    # Slots in Client/Config/FrameOrder.lua sharing a value (counted per extra slot), plus any BindToRenderStep whose priority is
    # not a FrameOrder.Priority(...) read (W10).
    frame_order = open(os.path.join(CLIENT, "StarterPlayerScripts", "Client", "Config", "FrameOrder.lua"), encoding="utf-8").read()
    slot_values = {}
    for name, base, sign, offset in re.findall(
        r"^\t(\w+) = \{\s*Value = RP\.(\w+)\.Value(?:\s*([+-])\s*(\d+))?", frame_order, re.M
    ):
        value = RENDER_ENUM[base] + (int(offset) * (1 if sign == "+" else -1) if sign else 0)
        slot_values.setdefault(value, []).append(name)
    clashes = sum(len(names) - 1 for names in slot_values.values() if len(names) > 1)

    pattern = re.compile(r"BindToRenderStep\(\s*[^,]+,\s*([^,]+),")
    unrouted = 0
    for _, _, _, code in sources(CLIENT):
        for m in pattern.finditer(code):
            expr = m.group(1).strip()
            if expr.startswith("FrameOrder.Priority("):
                continue
            local = re.search(r"^local\s+" + re.escape(expr) + r"\s*=\s*FrameOrder\.Priority\(", code, re.M)
            if local is None:
                unrouted += 1
    return clashes + unrouted


def unscoped_player_tables():
    pattern = re.compile(r"^local\s+\w+\s*:\s*\{\s*\[Player\]\s*:.*\}\s*=\s*\{\}\s*$", re.M)
    return sum(len(pattern.findall(code)) for _, _, _, code in sources(SERVER))


def load_animation_bypass():
    allowed = {"AnimationManager.lua", "AnimatorUtil.lua", "LocalAnimator.lua"}
    return sum(code.count(":LoadAnimation(") for _, name, _, code in sources(CLIENT) if name not in allowed)


def spec_rig_builders():
    pattern = re.compile(r"local\s+function\s+make(Dummy|Rig|Character)\b")
    return sum(len(pattern.findall(code)) for _, _, _, code in sources(ROOT, specs=True))


def duplicate_functions():
    bodies = {}
    header = re.compile(r"^(?:local\s+)?function\s+[\w.:]+\s*\(.*$")
    for path, _, _, code in sources(ROOT):
        lines = code.split("\n")
        i = 0
        while i < len(lines):
            if header.match(lines[i]):
                j = i + 1
                while j < len(lines) and lines[j].rstrip() != "end":
                    j += 1
                body = [ln.strip() for ln in lines[i + 1 : j] if ln.strip()]
                if len(body) >= 6:
                    digest = hashlib.sha1("\n".join(body).encode()).hexdigest()
                    bodies.setdefault(digest, set()).add(path)
                i = j + 1
            else:
                i += 1
    return sum(len(paths) - 1 for paths in bodies.values() if len(paths) > 1)


def restraint_reads():
    # Direct reads of a restraint Attribute outside BodyRestraint. Exempt, by file, with the reason:
    # writers/owners reading their own flag, perception and display (not "may this body act" gates).
    exempt = {
        "BodyRestraint.lua": "the owner",
        "CombatCamera.lua": "change-driven camera mode cache; moves with the camera owner (W11)",
        "FlightController.lua": "reads its own Flying state",
        "FlightCamera.lua": "camera mode, W11",
        "FlightAnimator.lua": "animation channel, W11",
        "CombatAnimator.lua": "animation channel, W11",
        "MovementVFX.lua": "presentation",
        "GrabSystem.lua": "writes and reads its own grab flags",
        "GrabInputClient.lua": "its own grab flag (Throw is only sent while holding)",
        "SwingRootClient.lua": "its own swing root",
        "TrainingBotSystem.lua": "a bot's perception, not a gate",
        "DebugDummySystem.lua": "a debug label",
        "KnockbackAudit.lua": "an audit's skip rule, not a gate",
        "ParkourMotor.lua": "the motor yields to RootControl mid-drive (a hold, not a refusal)",
        "ParkourInput.lua": "input routing for a mounted body (W12 Vehicle layer)",
        "VesselMount.lua": "the Mounted writer",
        "RootControl.lua": "the RootControlLocked writer",
    }
    pattern = re.compile(
        r"GetAttribute\((?:AttributeConstants|ATTRIBUTES)\.(?:Frozen|Grabbed|Grabbing|GrabThrowing|Mounted|Flying|"
        r"RootControlLocked|SwingRooted|EmoteMovementLocked)\)"
    )
    return sum(len(pattern.findall(code)) for _, name, _, code in sources(ROOT) if name not in exempt)


def settings_hub_requires():
    # SettingsClient requiring a gameplay module (anything outside Settings/, UI/, Input/, Network/): the push-hub W14 removed.
    path = os.path.join(CLIENT, "StarterPlayerScripts", "Client", "Settings", "SettingsClient.lua")
    code = strip_comments(open(path, encoding="utf-8").read())
    allowed = ("Settings", "UI", "Input", "Network")
    count = 0
    for m in re.finditer(r"require\(script\.Parent(?:\.Parent)?\.(\w+)", code):
        if m.group(1) not in allowed and m.group(1) not in ("SettingsStore", "SettingsWriteCoalescer"):
            count += 1
    return count


def vessel_shared_lines():
    # Code lines BlimpSystem and BoatSystem (and their two client controllers) share verbatim, in runs of >= 6 lines, once the
    # vehicle's name is normalised away. A shared run belongs in Shared/Vessel or Server/Vessel.
    import difflib

    def norm(path):
        out = []
        for line in open(path, encoding="utf-8").read().splitlines():
            line = line.rstrip()
            for a, b in (("Blimp", "X"), ("blimp", "x"), ("Boat", "X"), ("boat", "x")):
                line = line.replace(a, b)
            out.append(line)
        return out

    pairs = [
        ("ServerScriptService/Server/Systems/BlimpSystem.lua", "ServerScriptService/Server/Systems/BoatSystem.lua"),
        (
            "StarterPlayer/StarterPlayerScripts/Client/Blimp/BlimpController.lua",
            "StarterPlayer/StarterPlayerScripts/Client/Boat/BoatController.lua",
        ),
    ]
    total = 0
    for a, b in pairs:
        na, nb = norm(os.path.join(ROOT, a)), norm(os.path.join(ROOT, b))
        matcher = difflib.SequenceMatcher(None, na, nb, autojunk=False)
        for block in matcher.get_matching_blocks():
            if block.size >= 6:
                # Comments and requires are not duplicated logic: two files requiring the same shared module is the goal.
                code = [
                    l
                    for l in na[block.a : block.a + block.size]
                    if l.strip() and not l.strip().startswith("--") and " = require(" not in l
                ]
                if len(code) >= 4:
                    total += len(code)
    return total


def highlight_bypass():
    # Client Highlights made outside Client/FX/HighlightBudget.lua: each one is outside the engine's 31-Highlight budget (W19).
    needle = 'Instance.new("Highlight")'
    return sum(code.count(needle) for _, name, _, code in sources(CLIENT) if name != "HighlightBudget.lua")


def stale_combatsystem():
    return sum(len(re.findall(r"\bCombatSystem\b", raw)) for _, _, raw, _ in sources(ROOT))


MEASURES = [
    ("typeof_server", typeof_server, 90),
    ("nan_checks", nan_checks, 0),
    ("bare_remote_handlers", bare_remote_handlers, 0),
    ("raw_input_files", raw_input_files, 0),
    ("shared_render_priority", shared_render_priority, 0),
    ("unscoped_player_tables", unscoped_player_tables, 0),
    ("load_animation_bypass", load_animation_bypass, 0),
    ("spec_rig_builders", spec_rig_builders, 0),
    ("duplicate_functions", duplicate_functions, 4),
    ("restraint_reads", restraint_reads, 0),
    ("settings_hub_requires", settings_hub_requires, 0),
    ("vessel_shared_lines", vessel_shared_lines, 80),
    ("highlight_bypass", highlight_bypass, 0),
    ("stale_combatsystem", stale_combatsystem, 0),
]


def main():
    update = "--update" in sys.argv
    ceilings = json.load(open(CEILINGS)) if os.path.exists(CEILINGS) else {}
    rows, failed = [], False
    for name, measure, target in MEASURES:
        now = measure()
        ceiling = ceilings.get(name)
        if ceiling is None:
            status, ceilings[name] = "new", now
        elif now > ceiling:
            status, failed = "ROSE", True
        elif now < ceiling:
            status = "fell"
            if update:
                ceilings[name] = now
        else:
            status = "ok"
        rows.append((name, now, ceilings[name], target, status))

    width = max(len(r[0]) for r in rows)
    print(f"{'measure'.ljust(width)}  {'now':>5}  {'ceiling':>7}  {'target':>6}  status")
    for name, now, ceiling, target, status in rows:
        print(f"{name.ljust(width)}  {now:>5}  {ceiling:>7}  {target:>6}  {status}")

    if update or any(r[4] == "new" for r in rows):
        with open(CEILINGS, "w") as handle:
            json.dump(ceilings, handle, indent=2, sort_keys=True)
            handle.write("\n")
    if failed:
        print("\nA measure rose above its ceiling: a new copy of something the codebase already has one of. Use that one.")
        sys.exit(1)


if __name__ == "__main__":
    main()
