"""Move Editor source writer -- the local helper behind the Move Editor's Studio-only "Write to source".

A running Roblox server cannot write into this repository, and play-mode edits are thrown away on Stop.
So the Studio play-mode server generates a Lua module for a move (Support/MoveSourceWriter.lua) and POSTs
it here; this writes it under src/ServerScriptService/Server/Combat/AuthoredMoves/, Rojo syncs it into
the edit DataModel, and it ships with the build and lives in git. See
docs/design/move-editor-guide.md ("Writing a move into the game's source").

    python scripts/move-writer.py              serve on 127.0.0.1:34880 until Ctrl+C
    python scripts/move-writer.py --self-test  exercise the write/delete/refusal rules in a temp dir

Endpoints (JSON in, JSON out):
    GET  /health                                   -> {"ok": true, "root": "<AuthoredMoves path>"}
    POST /write  {"kind", "id", "source"}          -> {"ok": true, "path": "<repo-relative path>"}
    POST /delete {"kind", "id"}                    -> {"ok": true, "path": ..., "existed": bool}

Hard rules: bound to 127.0.0.1 only; "kind" is "move" or "override"; "id" matches ^[\\w:\\-]{1,64}$; the
body is at most 256 KB of UTF-8; and the resolved target must sit inside the AuthoredMoves folder (a path
that escapes it is refused, whatever the id sanitises to). Standard library only.
"""

import argparse
import json
import re
import shutil
import subprocess
import sys
import tempfile
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

HOST = "127.0.0.1"
PORT = 34880
MAX_BODY_BYTES = 256 * 1024
ID_PATTERN = re.compile(r"^[\w:\-]{1,64}$")
KIND_FOLDERS = {"move": "Moves", "override": "Overrides"}

REPO_ROOT = Path(__file__).resolve().parent.parent
AUTHORED_ROOT = REPO_ROOT / "src" / "ServerScriptService" / "Server" / "Combat" / "AuthoredMoves"


class Refused(Exception):
    """A request this helper will not carry out -- reported to the caller, never raised past the handler."""


def file_name(move_id: str) -> str:
    # The same rule as Support/MoveSourceWriter.FileName: everything outside [A-Za-z0-9-] becomes "_".
    return re.sub(r"[^A-Za-z0-9\-]", "_", move_id) + ".lua"


def target_path(root: Path, kind: str, move_id: str) -> Path:
    if kind not in KIND_FOLDERS:
        raise Refused(f"unknown kind {kind!r}")
    if not isinstance(move_id, str) or not ID_PATTERN.match(move_id):
        raise Refused("id must match ^[\\w:\\-]{1,64}$")
    folder = (root / KIND_FOLDERS[kind]).resolve()
    target = (folder / file_name(move_id)).resolve()
    # Belt and braces: the sanitiser already cannot produce a separator, but the refusal must not depend on it.
    if target.parent != folder or root.resolve() not in target.parents:
        raise Refused("resolved path escapes the AuthoredMoves folder")
    return target


def relative(path: Path) -> str:
    try:
        return path.relative_to(REPO_ROOT).as_posix()
    except ValueError:
        return path.as_posix()


def run_stylua(path: Path) -> None:
    stylua = shutil.which("stylua")
    if stylua:
        subprocess.run([stylua, str(path)], check=False, capture_output=True)


def write_move(root: Path, payload: dict) -> dict:
    target = target_path(root, payload.get("kind"), payload.get("id"))
    source = payload.get("source")
    if not isinstance(source, str) or not source.strip():
        raise Refused("source must be non-empty text")
    target.parent.mkdir(parents=True, exist_ok=True)
    # newline="\n": the repo's stylua.toml pins Unix line endings.
    with open(target, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(source)
    run_stylua(target)
    print(f"[move-writer] wrote {relative(target)}", flush=True)
    return {"ok": True, "path": relative(target)}


def delete_move(root: Path, payload: dict) -> dict:
    target = target_path(root, payload.get("kind"), payload.get("id"))
    existed = target.exists()
    if existed:
        target.unlink()
    print(f"[move-writer] {'deleted' if existed else 'nothing to delete at'} {relative(target)}", flush=True)
    return {"ok": True, "path": relative(target), "existed": existed}


def make_handler(root: Path):
    class Handler(BaseHTTPRequestHandler):
        def _reply(self, status: int, payload: dict) -> None:
            body = json.dumps(payload).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, format, *args):  # noqa: A002 -- the base class's own signature
            pass  # Each action already logs one line of its own.

        def do_GET(self):
            if self.path == "/health":
                self._reply(200, {"ok": True, "root": str(root)})
            else:
                self._reply(404, {"ok": False, "error": "not found"})

        def do_POST(self):
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if length > MAX_BODY_BYTES:
                    raise Refused("body larger than 256 KB")
                raw = self.rfile.read(length)
                payload = json.loads(raw.decode("utf-8"))
                if not isinstance(payload, dict):
                    raise Refused("body must be a JSON object")
                if self.path == "/write":
                    self._reply(200, write_move(root, payload))
                elif self.path == "/delete":
                    self._reply(200, delete_move(root, payload))
                else:
                    self._reply(404, {"ok": False, "error": "not found"})
            except (Refused, ValueError, UnicodeDecodeError) as problem:
                print(f"[move-writer] refused: {problem}", flush=True)
                self._reply(400, {"ok": False, "error": str(problem)})

    return Handler


def self_test() -> int:
    with tempfile.TemporaryDirectory() as temp:
        root = Path(temp) / "AuthoredMoves"
        root.mkdir()
        written = write_move(root, {"kind": "move", "id": "rising-palm-4821", "source": "return {}\n"})
        assert written["ok"], written
        assert (root / "Moves" / "rising-palm-4821.lua").read_text(encoding="utf-8") == "return {}\n"
        write_move(root, {"kind": "override", "id": "default:Sword:Basic:1", "source": "return {}\n"})
        assert (root / "Overrides" / "default_Sword_Basic_1.lua").exists()

        for bad in (
            {"kind": "move", "id": "../escape", "source": "x"},
            {"kind": "move", "id": "a/b", "source": "x"},
            {"kind": "move", "id": "x" * 65, "source": "x"},
            {"kind": "script", "id": "ok-id", "source": "x"},
            {"kind": "move", "id": "ok-id", "source": ""},
        ):
            try:
                write_move(root, bad)
            except Refused:
                continue
            raise AssertionError(f"accepted {bad!r}")
        assert not any(Path(temp).glob("*.lua")), "a refused write landed outside the folder"

        deleted = delete_move(root, {"kind": "move", "id": "rising-palm-4821"})
        assert deleted["existed"] and not (root / "Moves" / "rising-palm-4821.lua").exists()
        assert not delete_move(root, {"kind": "move", "id": "rising-palm-4821"})["existed"]
    print("[move-writer] self-test passed", flush=True)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--self-test", action="store_true", help="run the rules against a temp dir and exit")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    AUTHORED_ROOT.mkdir(parents=True, exist_ok=True)
    server = HTTPServer((HOST, PORT), make_handler(AUTHORED_ROOT))
    print(f"[move-writer] writing into {relative(AUTHORED_ROOT)} -- listening on http://{HOST}:{PORT}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
