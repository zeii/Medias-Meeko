#!/usr/bin/env python3
"""Small local web UI around meeko_download: run it and a browser tab opens."""

import argparse
import errno
import json
import subprocess
import sys
import threading
import urllib.error
import webbrowser
from datetime import datetime, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import meeko_download as md

HERE = Path(__file__).resolve().parent
DEFAULT_OUT = Path.home() / "Pictures" / "Meeko"

state = {"token": md.load_token(), "items": {}}
job = {"running": False, "total": 0, "done": 0, "skipped": 0, "failed": 0, "current": None, "out": None, "error": None}
lock = threading.Lock()


def day_range(since, until):
    start = datetime.fromisoformat(since).astimezone() if since else datetime.fromtimestamp(0).astimezone()
    end = datetime.fromisoformat(until).astimezone() + timedelta(days=1, microseconds=-1) if until else datetime.now().astimezone()
    return start, end


def run_download(ids, out):
    manifest = md.load_manifest(out)
    selected = [state["items"][i] for i in ids if i in state["items"]]
    with lock:
        job.update(running=True, total=len(selected), done=0, skipped=0, failed=0, current=None, out=str(out), error=None)
    try:
        for item, taken in sorted(selected, key=lambda x: x[1]):
            with lock:
                job["current"] = f"{taken:%d/%m/%Y %H:%M}"
            try:
                _, downloaded = md.save_item(out, item, taken, manifest)
                key = "done" if downloaded else "skipped"
            except (urllib.error.URLError, OSError) as e:
                print(f"✗ {item.get('id')}: {e}", file=sys.stderr)
                key = "failed"
            with lock:
                job[key] += 1
        if manifest:
            md.save_manifest(out, manifest)
    except Exception as e:  # surface unexpected errors in the UI instead of a dead thread
        with lock:
            job["error"] = str(e)
    finally:
        with lock:
            job.update(running=False, current=None)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def send_json(self, code, payload):
        body = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def trusted(self):
        # Blocks other websites (CSRF / DNS rebinding) from driving this local server.
        port = self.server.server_address[1]
        allowed = {f"127.0.0.1:{port}", f"localhost:{port}"}
        if self.headers.get("Host") not in allowed:
            return False
        origin = self.headers.get("Origin")
        return origin is None or origin.split("://", 1)[-1] in allowed

    def do_GET(self):
        if not self.trusted():
            return self.send_json(403, {"error": "forbidden"})
        if self.path == "/":
            body = (HERE / "ui.html").read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path == "/favicon.png":
            body = (HERE / "assets" / "meeko-icon.png").read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path == "/api/status":
            self.send_json(200, {"logged_in": bool(state["token"]), "default_out": str(DEFAULT_OUT)})
        elif self.path == "/api/progress":
            with lock:
                self.send_json(200, dict(job))
        else:
            self.send_json(404, {"error": "not found"})

    def do_POST(self):
        if not self.trusted() or "application/json" not in (self.headers.get("Content-Type") or ""):
            return self.send_json(403, {"error": "forbidden"})
        length = int(self.headers.get("Content-Length") or 0)
        data = json.loads(self.rfile.read(length) or b"{}")
        route = {
            "/api/login": self.login,
            "/api/logout": self.logout,
            "/api/list": self.list_media,
            "/api/download": self.download,
            "/api/open": self.open_folder,
            "/api/quit": self.quit,
        }.get(self.path)
        if not route:
            return self.send_json(404, {"error": "not found"})
        try:
            route(data)
        except md.AuthError:
            state["token"] = None
            self.send_json(401, {"error": "Session expirée, reconnecte-toi."})
        except Exception as e:
            self.send_json(500, {"error": str(e)})

    def login(self, data):
        try:
            token = md.login(data.get("email", "").strip(), data.get("password", ""))
        except md.AuthError:
            return self.send_json(401, {"error": "Identifiants invalides."})
        md.save_token(token)
        state["token"] = token
        self.send_json(200, {"ok": True})

    def logout(self, _):
        state["token"] = None
        md.TOKEN_FILE.unlink(missing_ok=True)
        self.send_json(200, {"ok": True})

    def list_media(self, data):
        if not state["token"]:
            raise md.AuthError()
        since, until = day_range(data.get("since"), data.get("until"))
        out = Path(data.get("out") or DEFAULT_OUT).expanduser()
        items = md.collect(state["token"], since, until)
        state["items"] = {str(i["id"]): (i, t) for i, t in items}
        self.send_json(200, {"items": [
            {
                "id": str(i["id"]),
                "taken_at": t.isoformat(),
                "video": bool(i.get("video")),
                "url": i["photo_url"],
                "description": i.get("description"),
                "present": md.target_path(out, i, t)[1],
            }
            for i, t in items
        ]})

    def download(self, data):
        with lock:
            if job["running"]:
                return self.send_json(409, {"error": "Un téléchargement est déjà en cours."})
        out = Path(data.get("out") or DEFAULT_OUT).expanduser()
        out.mkdir(parents=True, exist_ok=True)
        threading.Thread(target=run_download, args=(data.get("ids", []), out), daemon=True).start()
        self.send_json(200, {"ok": True})

    def open_folder(self, data):
        out = Path(data.get("out") or DEFAULT_OUT).expanduser()
        out.mkdir(parents=True, exist_ok=True)
        subprocess.run(["open", str(out)], check=False)
        self.send_json(200, {"ok": True})

    def quit(self, _):
        with lock:
            if job["running"]:
                return self.send_json(409, {"error": "Un téléchargement est en cours."})
        self.send_json(200, {"ok": True})
        # shutdown() blocks until serve_forever exits, so it must run outside the request thread.
        threading.Thread(target=self.server.shutdown, daemon=True).start()


def main():
    p = argparse.ArgumentParser(description="Interface locale pour télécharger les médias Meeko Family.")
    p.add_argument("--port", type=int, default=8765)
    p.add_argument("--no-browser", action="store_true", help="n'ouvre pas le navigateur")
    args = p.parse_args()

    url = f"http://127.0.0.1:{args.port}/"
    try:
        server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    except OSError as e:
        if e.errno != errno.EADDRINUSE:
            raise
        # Another launch won the race: reuse the running instance.
        print(f"Déjà lancé sur {url}")
        if not args.no_browser:
            webbrowser.open(url)
        return
    print(f"Interface Meeko sur {url} (Ctrl+C pour quitter)")
    if not args.no_browser:
        threading.Timer(0.5, webbrowser.open, args=(url,)).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
