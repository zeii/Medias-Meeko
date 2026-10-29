#!/usr/bin/env python3
"""Download photos and videos published on Meeko Family since a given date."""

import argparse
import getpass
import json
import mimetypes
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta
from pathlib import Path

API = "https://api.meeko.app"
FAMILY_API = API + "/family/v1"
TOKEN_FILE = Path.home() / ".config" / "meeko" / "token.json"
PER_PAGE = 30  # same value as the official web app
USER_AGENT = "meeko-download/1.0"


class AuthError(Exception):
    pass


def http(method, url, token=None, body=None, params=None):
    if params:
        url += "?" + urllib.parse.urlencode(params)
    headers = {"Accept": "application/json", "User-Agent": USER_AGENT, "X-Requested-With": "XMLHttpRequest"}
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as e:
        payload = e.read().decode(errors="replace")
        if e.code == 401:
            raise AuthError(payload) from None
        if e.code == 422 and "invalid_credentials" in payload:
            raise AuthError("Identifiants invalides.") from None
        raise RuntimeError(f"{method} {url} -> HTTP {e.code}: {payload[:300]}") from None


def login(email, password):
    res = http("POST", API + "/v2/family/auth/login", body={"email": email, "password": password})
    return res["token"]


def load_token():
    try:
        return json.loads(TOKEN_FILE.read_text())["token"]
    except (OSError, ValueError, KeyError):
        return None


def save_token(token):
    TOKEN_FILE.parent.mkdir(parents=True, exist_ok=True)
    TOKEN_FILE.write_text(json.dumps({"token": token}))
    TOKEN_FILE.chmod(0o600)


def get_token(args, force_login=False):
    if not force_login:
        token = load_token()
        if token:
            return token
    email = args.email or os.environ.get("MEEKO_EMAIL") or input("Email Meeko : ").strip()
    password = os.environ.get("MEEKO_PASSWORD") or getpass.getpass("Mot de passe Meeko : ")
    token = login(email, password)
    save_token(token)
    return token


def parse_ts(value):
    """taken_at is either a unix timestamp or an ISO 8601 string depending on the endpoint."""
    if value is None:
        return None
    if isinstance(value, (int, float)) or str(value).isdigit():
        return datetime.fromtimestamp(int(value)).astimezone()
    return datetime.fromisoformat(str(value).replace("Z", "+00:00")).astimezone()


def parse_date_arg(value):
    return datetime.fromisoformat(value).astimezone()


def iter_photos(token):
    page = 1
    while True:
        res = http("GET", FAMILY_API + "/photos", token=token, params={"per_page": PER_PAGE, "page": page})
        yield from res.get("data", [])
        if page >= res.get("last_page", page):
            return
        page += 1


def guess_ext(item, content_type=None):
    ext = Path(urllib.parse.urlparse(item["photo_url"]).path).suffix.lower()
    if ext and len(ext) <= 5:
        return ext
    if content_type:
        guessed = mimetypes.guess_extension(content_type.split(";")[0].strip())
        if guessed:
            return guessed
    if item.get("type") and "/" not in str(item["type"]):
        return "." + str(item["type"]).lower()
    return ".mp4" if item.get("video") else ".jpg"


def download(url, dest):
    headers = {"User-Agent": USER_AGENT}
    req = urllib.request.Request(url, headers=headers)
    tmp = dest.with_suffix(dest.suffix + ".part")
    with urllib.request.urlopen(req, timeout=300) as resp, open(tmp, "wb") as f:
        while chunk := resp.read(1 << 16):
            f.write(chunk)
    tmp.rename(dest)


def target_path(out, item, taken):
    stem = f"{taken:%Y-%m-%d_%H%M%S}_{item['id']}"
    folder = out / f"{taken:%Y}" / f"{taken:%m}"
    existing = list(folder.glob(stem + ".*")) if folder.exists() else []
    existing = [p for p in existing if not p.name.endswith(".part")]
    if existing:
        return existing[0], True
    return folder / (stem + guess_ext(item)), False


def load_manifest(out):
    path = out / "manifest.json"
    return json.loads(path.read_text()) if path.exists() else {}


def save_manifest(out, manifest):
    (out / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2))


def save_item(out, item, taken, manifest):
    """Download one media unless already present. Returns (path, downloaded)."""
    dest, exists = target_path(out, item, taken)
    if exists:
        return dest, False
    dest.parent.mkdir(parents=True, exist_ok=True)
    download(item["photo_url"], dest)
    ts = taken.timestamp()
    os.utime(dest, (ts, ts))
    manifest[str(item["id"])] = {
        "file": str(dest.relative_to(out)),
        "taken_at": taken.isoformat(),
        "video": bool(item.get("video")),
        "description": item.get("description"),
    }
    return dest, True


def collect(token, since, until):
    selected = []
    for item in iter_photos(token):
        taken = parse_ts(item.get("taken_at") or item.get("created_at"))
        if taken is None:
            continue
        # The API returns newest first, so the first item older than `since` ends the scan.
        if taken < since:
            break
        if taken <= until:
            selected.append((item, taken))
    return selected


def main():
    p = argparse.ArgumentParser(description="Télécharge les photos/vidéos Meeko Family publiées depuis une date.")
    p.add_argument("since", nargs="?", help="date de début, ex: 2026-09-01 (défaut: tout l'historique)")
    p.add_argument("--until", help="date de fin incluse (défaut: maintenant)")
    p.add_argument("-o", "--out", default="meeko-media", help="dossier de sortie (défaut: ./meeko-media)")
    p.add_argument("--email", help="email du compte Meeko (sinon MEEKO_EMAIL ou saisie)")
    p.add_argument("--dry-run", action="store_true", help="liste sans télécharger")
    p.add_argument("--relogin", action="store_true", help="ignore le token en cache")
    args = p.parse_args()

    since = parse_date_arg(args.since) if args.since else datetime.fromtimestamp(0).astimezone()
    until = parse_date_arg(args.until) if args.until else datetime.now().astimezone()
    if args.until and len(args.until) == 10:
        until += timedelta(days=1, microseconds=-1)
    out = Path(args.out).expanduser()

    try:
        token = get_token(args, force_login=args.relogin)
        try:
            items = collect(token, since, until)
        except AuthError:
            token = get_token(args, force_login=True)
            items = collect(token, since, until)
    except AuthError as e:
        sys.exit(f"Échec d'authentification : {e}")

    print(f"{len(items)} média(s) entre {since:%Y-%m-%d %H:%M} et {until:%Y-%m-%d %H:%M}")
    manifest = load_manifest(out)

    done = skipped = failed = 0
    for item, taken in reversed(items):
        dest, exists = target_path(out, item, taken)
        label = f"{taken:%Y-%m-%d %H:%M} {'vidéo' if item.get('video') else 'photo'} {dest.name}"
        if exists:
            skipped += 1
            continue
        if args.dry_run:
            print("  " + label)
            continue
        try:
            save_item(out, item, taken, manifest)
        except (urllib.error.URLError, OSError) as e:
            failed += 1
            print(f"  ✗ {label} : {e}", file=sys.stderr)
            continue
        done += 1
        print("  ✓ " + label)
        time.sleep(0.1)

    if done:
        save_manifest(out, manifest)
    print(f"Terminé : {done} téléchargé(s), {skipped} déjà présent(s), {failed} échec(s) → {out}")
    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
