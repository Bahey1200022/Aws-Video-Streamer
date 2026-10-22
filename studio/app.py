"""Stream Studio: manage live channels on the MSS streaming platform.

Runs behind nginx (reverse proxy on /studio/) and listens on 127.0.0.1 only.
nginx-rtmp calls /studio/internal/publish-auth before accepting any stream.
"""
import base64
import hashlib
import hmac
import ipaddress
import os
import re
import secrets
import socket
import sqlite3
import subprocess
import threading
import time
from functools import wraps
from urllib.parse import urlsplit

import requests
from flask import (Flask, abort, flash, g, has_request_context, redirect,
                   render_template, request, session, url_for)
from werkzeug.middleware.proxy_fix import ProxyFix
from werkzeug.security import check_password_hash, generate_password_hash

DATA_DIR = os.environ.get("STUDIO_DATA", "/data")
DB_PATH = os.path.join(DATA_DIR, "studio.db")
VIDEO_DIR = os.path.join(DATA_DIR, "videos")
RTMP_BASE = os.environ.get("STUDIO_RTMP", "rtmp://127.0.0.1:1935")
LINK_SECRET = os.environ["STUDIO_LINK_SECRET"]
MAX_IMPORT_BYTES = int(os.environ.get("STUDIO_MAX_IMPORT_MB", "200")) * 1024 * 1024
MAX_RUNNING = int(os.environ.get("STUDIO_MAX_RUNNING", "2"))
SHARE_LINK_TTL = 24 * 3600
PLAYBACK_TTL = 4 * 3600
SYSTEM_CHANNEL = "stream"  # fed by the Video Streamer over WireGuard

CHANNEL_RE = re.compile(r"^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$")
USERNAME_RE = re.compile(r"^[a-zA-Z0-9_.-]{3,32}$")

app = Flask(__name__, static_url_path="/studio/static")
app.config.update(
    SECRET_KEY=os.environ["STUDIO_SECRET_KEY"],
    SESSION_COOKIE_NAME="studio_session",
    SESSION_COOKIE_PATH="/studio",
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SAMESITE="Lax",
    SESSION_COOKIE_SECURE=os.environ.get("STUDIO_COOKIE_SECURE", "0") == "1",
    PERMANENT_SESSION_LIFETIME=8 * 3600,
    MAX_CONTENT_LENGTH=16 * 1024,
)
# nginx sets X-Forwarded-For to the client address (overwriting, not appending)
app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1)


# --------------------------------------------------------------------------- db

SCHEMA = """
CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY,
    username TEXT UNIQUE NOT NULL,
    pw_hash TEXT NOT NULL,
    role TEXT NOT NULL CHECK (role IN ('admin', 'user'))
);
CREATE TABLE IF NOT EXISTS channels (
    id INTEGER PRIMARY KEY,
    name TEXT UNIQUE NOT NULL,
    owner_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    stream_key TEXT NOT NULL,
    private INTEGER NOT NULL DEFAULT 0,
    link_salt TEXT NOT NULL,
    system INTEGER NOT NULL DEFAULT 0,
    video_status TEXT NOT NULL DEFAULT 'none',
    running INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY,
    ts TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    username TEXT,
    ip TEXT,
    action TEXT NOT NULL,
    detail TEXT
);
"""


def connect():
    conn = sqlite3.connect(DB_PATH, timeout=10)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    return conn


def db():
    if "db" not in g:
        g.db = connect()
    return g.db


@app.teardown_appcontext
def close_db(_exc):
    conn = g.pop("db", None)
    if conn is not None:
        conn.close()


def audit(action, detail="", username=None, ip=None, conn=None):
    """Append to the audit log. Never pass secrets in detail."""
    if username is None and has_request_context():
        username = session.get("username")
    if ip is None and has_request_context():
        ip = request.remote_addr
    c = conn or db()
    c.execute("INSERT INTO events (username, ip, action, detail) VALUES (?, ?, ?, ?)",
              (username, ip, action, detail))
    c.commit()


def init_db():
    os.makedirs(VIDEO_DIR, exist_ok=True)
    conn = connect()
    conn.executescript(SCHEMA)
    # The admin password and the system stream key come from Terraform; keep
    # the database in sync with them on every start
    admin_pw = os.environ["STUDIO_ADMIN_PASSWORD"]
    row = conn.execute("SELECT id FROM users WHERE username = 'admin'").fetchone()
    if row:
        conn.execute("UPDATE users SET pw_hash = ?, role = 'admin' WHERE id = ?",
                     (generate_password_hash(admin_pw), row["id"]))
        admin_id = row["id"]
    else:
        admin_id = conn.execute(
            "INSERT INTO users (username, pw_hash, role) VALUES ('admin', ?, 'admin')",
            (generate_password_hash(admin_pw),)).lastrowid
    seed_key = os.environ.get("STUDIO_SEED_STREAM_KEY")
    if seed_key:
        conn.execute(
            "INSERT INTO channels (name, owner_id, stream_key, link_salt, system) "
            "VALUES (?, ?, ?, ?, 1) "
            "ON CONFLICT(name) DO UPDATE SET stream_key = excluded.stream_key, system = 1",
            (SYSTEM_CHANNEL, admin_id, seed_key, secrets.token_hex(8)))
    conn.commit()
    conn.close()


# ------------------------------------------------------------------- security

@app.before_request
def csrf_protect():
    if request.method == "POST":
        sent = request.form.get("csrf_token", "")
        if not sent or not hmac.compare_digest(sent, session.get("csrf_token", "")):
            abort(400, "Invalid or missing CSRF token")


@app.context_processor
def inject_csrf():
    if "csrf_token" not in session:
        session["csrf_token"] = secrets.token_urlsafe(32)
    return {"csrf_token": session["csrf_token"], "me": current_user()}


def current_user():
    uid = session.get("user_id")
    if uid is None:
        return None
    return db().execute("SELECT id, username, role FROM users WHERE id = ?", (uid,)).fetchone()


def login_required(view):
    @wraps(view)
    def wrapped(*args, **kwargs):
        if current_user() is None:
            return redirect(url_for("login"))
        return view(*args, **kwargs)
    return wrapped


def admin_required(view):
    @wraps(view)
    @login_required
    def wrapped(*args, **kwargs):
        if current_user()["role"] != "admin":
            audit("access_denied", request.path)
            abort(403)
        return view(*args, **kwargs)
    return wrapped


def channel_for_user(name):
    """Return the channel if the current user owns it (or is admin), else 404."""
    ch = db().execute("SELECT * FROM channels WHERE name = ?", (name,)).fetchone()
    me = current_user()
    if ch is None or (me["role"] != "admin" and ch["owner_id"] != me["id"]):
        abort(404)  # don't reveal whether someone else's channel exists
    return ch


# ---------------------------------------------------------------- signed URLs

def share_signature(ch, expires):
    msg = f"{ch['name']}:{expires}:{ch['link_salt']}".encode()
    return hmac.new(app.config["SECRET_KEY"].encode(), msg, hashlib.sha256).hexdigest()[:32]


PLAYBACK_PATH_RE = re.compile(
    r"^/private/(?P<tok>[A-Za-z0-9_-]{43})/(?P<exp>[0-9]{1,12})/"
    r"(?P<chan>[a-z0-9-]+)(?:-[0-9]+\.ts|\.m3u8)$")


def playback_token(name, expires):
    """HMAC-SHA256 over "<expires>:<channel>", verified on every HLS request."""
    mac = hmac.new(LINK_SECRET.encode(), f"{expires}:{name}".encode(), hashlib.sha256).digest()
    return base64.urlsafe_b64encode(mac).decode().rstrip("=")


# ------------------------------------------------------------- SSRF defences

class ImportBlocked(Exception):
    pass


def check_destination(url):
    """Allow only http(s) on default ports to public internet addresses."""
    parts = urlsplit(url)
    if parts.scheme not in ("http", "https"):
        raise ImportBlocked("only http and https URLs are allowed")
    if not parts.hostname:
        raise ImportBlocked("URL has no host")
    if parts.port not in (None, 80, 443):
        raise ImportBlocked("non-standard ports are not allowed")
    if parts.username or parts.password:
        raise ImportBlocked("credentials in URLs are not allowed")
    try:
        infos = socket.getaddrinfo(parts.hostname, parts.port or 443, proto=socket.IPPROTO_TCP)
    except socket.gaierror:
        raise ImportBlocked("host does not resolve")
    for info in infos:
        ip = ipaddress.ip_address(info[4][0])
        if not ip.is_global or ip.is_multicast:
            # covers 127.0.0.0/8, 10/8, 192.168/16, 169.254.169.254 (metadata), ...
            raise ImportBlocked(f"destination address {ip} is not a public address")


def download_video(url, dest):
    """Fetch url to dest, re-validating every redirect hop and capping the size."""
    for _hop in range(4):
        check_destination(url)
        with requests.get(url, stream=True, timeout=(5, 30), allow_redirects=False) as resp:
            if resp.is_redirect:
                url = requests.compat.urljoin(url, resp.headers.get("Location", ""))
                continue
            resp.raise_for_status()
            size = 0
            with open(dest, "wb") as fh:
                for chunk in resp.iter_content(chunk_size=1 << 16):
                    size += len(chunk)
                    if size > MAX_IMPORT_BYTES:
                        raise ImportBlocked(f"file is larger than {MAX_IMPORT_BYTES >> 20} MB")
                    fh.write(chunk)
            return
    raise ImportBlocked("too many redirects")


def probe(path):
    """Return {'video': codec, 'audio': codec} or raise if it isn't a usable video."""
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "stream=codec_type,codec_name",
         "-of", "csv=p=0", path],
        capture_output=True, text=True, timeout=30)
    codecs = {}
    for line in out.stdout.splitlines():
        name, _, kind = line.partition(",")
        if kind in ("video", "audio") and kind not in codecs:
            codecs[kind] = name
    if "video" not in codecs:
        raise ImportBlocked("file is not a video ffmpeg can read")
    return codecs


def import_worker(channel_id, name, url, username, ip):
    conn = connect()
    final = os.path.join(VIDEO_DIR, f"{name}.mp4")
    tmp = final + ".part"
    try:
        download_video(url, tmp)
        probe(tmp)
        os.replace(tmp, final)
        conn.execute("UPDATE channels SET video_status = 'ready' WHERE id = ?", (channel_id,))
        audit("import_ok", f"channel={name} host={urlsplit(url).hostname}", username, ip, conn)
    except ImportBlocked as exc:
        conn.execute("UPDATE channels SET video_status = 'blocked' WHERE id = ?", (channel_id,))
        audit("import_blocked", f"channel={name} reason={exc}", username, ip, conn)
    except Exception as exc:  # network errors, HTTP errors, ...
        conn.execute("UPDATE channels SET video_status = 'failed' WHERE id = ?", (channel_id,))
        audit("import_failed", f"channel={name} error={type(exc).__name__}", username, ip, conn)
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)
        conn.commit()
        conn.close()


# ------------------------------------------------------- ffmpeg process table

procs = {}
procs_lock = threading.Lock()


def ffmpeg_cmd(ch):
    path = os.path.join(VIDEO_DIR, f"{ch['name']}.mp4")
    rtmp_app = "private" if ch["private"] else "live"
    target = f"{RTMP_BASE}/{rtmp_app}/{ch['name']}?key={ch['stream_key']}"
    codecs = probe(path)
    if codecs.get("video") == "h264" and codecs.get("audio") in (None, "aac"):
        encode = ["-c", "copy"]  # already browser-friendly: no CPU cost
    else:
        encode = ["-vf", "scale=-2:360", "-c:v", "libx264", "-preset", "veryfast",
                  "-b:v", "800k", "-c:a", "aac", "-b:a", "96k"]
    return ["ffmpeg", "-nostdin", "-loglevel", "error", "-re", "-stream_loop", "-1",
            "-i", path, *encode, "-f", "flv", target]


def is_live(name):
    with procs_lock:
        p = procs.get(name)
        return p is not None and p.poll() is None


def start_proc(ch):
    with procs_lock:
        old = procs.get(ch["name"])
        if old is not None and old.poll() is None:
            return
        procs[ch["name"]] = subprocess.Popen(ffmpeg_cmd(ch), stdin=subprocess.DEVNULL,
                                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def stop_proc(name):
    with procs_lock:
        p = procs.pop(name, None)
    if p is not None and p.poll() is None:
        p.terminate()
        try:
            p.wait(timeout=5)
        except subprocess.TimeoutExpired:
            p.kill()


def supervisor():
    """Keep channels marked running alive (e.g. after an nginx reload)."""
    while True:
        try:
            conn = connect()
            for ch in conn.execute("SELECT * FROM channels WHERE running = 1 AND system = 0"):
                if not is_live(ch["name"]):
                    try:
                        start_proc(ch)
                    except Exception:
                        pass
            conn.close()
        except Exception:
            pass
        time.sleep(10)


# --------------------------------------------------------------------- routes

@app.route("/studio/")
@login_required
def dashboard():
    me = current_user()
    if me["role"] == "admin":
        rows = db().execute(
            "SELECT c.*, u.username AS owner FROM channels c JOIN users u ON u.id = c.owner_id "
            "ORDER BY c.system DESC, c.name").fetchall()
    else:
        rows = db().execute(
            "SELECT c.*, u.username AS owner FROM channels c JOIN users u ON u.id = c.owner_id "
            "WHERE c.owner_id = ? ORDER BY c.name", (me["id"],)).fetchall()
    channels = [dict(r, live=(r["system"] or is_live(r["name"]))) for r in rows]
    return render_template("dashboard.html", channels=channels, max_running=MAX_RUNNING)


@app.route("/studio/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        username = request.form.get("username", "")[:64]
        password = request.form.get("password", "")
        recent_failures = db().execute(
            "SELECT COUNT(*) FROM events WHERE action = 'login_failed' AND username = ? "
            "AND ts > strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-15 minutes')",
            (username,)).fetchone()[0]
        if recent_failures >= 5:
            audit("login_locked", "", username)
            flash("Too many failed attempts. Try again in 15 minutes.", "error")
            return render_template("login.html"), 429
        user = db().execute("SELECT * FROM users WHERE username = ?", (username,)).fetchone()
        if user and check_password_hash(user["pw_hash"], password):
            session.clear()  # new session on login (no fixation)
            session.permanent = True
            session["user_id"] = user["id"]
            session["username"] = user["username"]
            audit("login_ok")
            return redirect(url_for("dashboard"))
        audit("login_failed", "", username)
        flash("Invalid username or password.", "error")  # same message either way
    return render_template("login.html")


@app.route("/studio/logout", methods=["POST"])
@login_required
def logout():
    audit("logout")
    session.clear()
    return redirect(url_for("login"))


@app.route("/studio/channels", methods=["POST"])
@login_required
def create_channel():
    me = current_user()
    name = request.form.get("name", "").strip().lower()
    if not CHANNEL_RE.match(name) or name == SYSTEM_CHANNEL:
        flash("Channel names: 3-32 chars, lowercase letters, digits and hyphens.", "error")
        return redirect(url_for("dashboard"))
    try:
        db().execute(
            "INSERT INTO channels (name, owner_id, stream_key, private, link_salt) "
            "VALUES (?, ?, ?, ?, ?)",
            (name, me["id"], secrets.token_urlsafe(24),
             1 if request.form.get("private") else 0, secrets.token_hex(8)))
        db().commit()
    except sqlite3.IntegrityError:
        flash("That channel name is taken.", "error")
        return redirect(url_for("dashboard"))
    audit("channel_create", f"channel={name}")
    flash(f"Channel {name} created.", "ok")
    return redirect(url_for("dashboard"))


@app.route("/studio/channels/<name>/delete", methods=["POST"])
@login_required
def delete_channel(name):
    ch = channel_for_user(name)
    if ch["system"]:
        abort(400, "The system channel can't be deleted")
    stop_proc(name)
    db().execute("DELETE FROM channels WHERE id = ?", (ch["id"],))
    db().commit()
    path = os.path.join(VIDEO_DIR, f"{name}.mp4")
    if os.path.exists(path):
        os.remove(path)
    audit("channel_delete", f"channel={name}")
    return redirect(url_for("dashboard"))


@app.route("/studio/channels/<name>/rotate-key", methods=["POST"])
@login_required
def rotate_key(name):
    ch = channel_for_user(name)
    if ch["system"]:
        abort(400, "Rotate the system key with Terraform")
    db().execute("UPDATE channels SET stream_key = ? WHERE id = ?",
                 (secrets.token_urlsafe(24), ch["id"]))
    db().commit()
    if is_live(name):  # reconnect with the new key
        stop_proc(name)
        start_proc(db().execute("SELECT * FROM channels WHERE id = ?", (ch["id"],)).fetchone())
    audit("key_rotate", f"channel={name}")
    flash(f"New stream key for {name}.", "ok")
    return redirect(url_for("dashboard"))


@app.route("/studio/channels/<name>/revoke-links", methods=["POST"])
@login_required
def revoke_links(name):
    ch = channel_for_user(name)
    db().execute("UPDATE channels SET link_salt = ? WHERE id = ?", (secrets.token_hex(8), ch["id"]))
    db().commit()
    audit("links_revoked", f"channel={name}")
    flash(f"All share links for {name} are now invalid.", "ok")
    return redirect(url_for("dashboard"))


@app.route("/studio/channels/<name>/import", methods=["POST"])
@login_required
def import_video(name):
    ch = channel_for_user(name)
    if ch["system"]:
        abort(400, "The system channel is fed by the Video Streamer")
    url = request.form.get("url", "").strip()[:2048]
    try:
        check_destination(url)  # fail fast; re-checked for every redirect hop
    except ImportBlocked as exc:
        audit("import_blocked", f"channel={name} reason={exc}")
        flash(f"Import blocked: {exc}.", "error")
        return redirect(url_for("dashboard"))
    db().execute("UPDATE channels SET video_status = 'importing' WHERE id = ?", (ch["id"],))
    db().commit()
    audit("import_start", f"channel={name} host={urlsplit(url).hostname}")
    threading.Thread(target=import_worker, daemon=True,
                     args=(ch["id"], name, url, session.get("username"), request.remote_addr)).start()
    flash("Import started. Refresh to see its status.", "ok")
    return redirect(url_for("dashboard"))


@app.route("/studio/channels/<name>/start", methods=["POST"])
@login_required
def start_channel(name):
    ch = channel_for_user(name)
    if ch["system"] or ch["video_status"] != "ready":
        abort(400, "Import a video first")
    running = sum(1 for n in list(procs) if is_live(n))
    if running >= MAX_RUNNING and not is_live(name):
        flash(f"At most {MAX_RUNNING} channels can be live at once.", "error")
        return redirect(url_for("dashboard"))
    start_proc(ch)
    db().execute("UPDATE channels SET running = 1 WHERE id = ?", (ch["id"],))
    db().commit()
    audit("stream_start", f"channel={name}")
    return redirect(url_for("dashboard"))


@app.route("/studio/channels/<name>/stop", methods=["POST"])
@login_required
def stop_channel(name):
    ch = channel_for_user(name)
    stop_proc(name)
    db().execute("UPDATE channels SET running = 0 WHERE id = ?", (ch["id"],))
    db().commit()
    audit("stream_stop", f"channel={name}")
    return redirect(url_for("dashboard"))


@app.route("/studio/channels/<name>/share", methods=["POST"])
@login_required
def share_link(name):
    ch = channel_for_user(name)
    expires = int(time.time()) + SHARE_LINK_TTL
    link = url_for("watch", name=name, e=expires, s=share_signature(ch, expires), _external=True)
    audit("share_link", f"channel={name}")
    flash(f"Share link (valid 24 h): {link}", "link")
    return redirect(url_for("dashboard"))


@app.route("/studio/watch/<name>")
def watch(name):
    ch = db().execute("SELECT * FROM channels WHERE name = ?", (name,)).fetchone()
    if ch is None:
        abort(404)
    if not ch["private"]:
        return render_template("watch.html", ch=ch, src=f"/hls/{name}.m3u8")

    me = current_user()
    allowed = me is not None and (me["role"] == "admin" or me["id"] == ch["owner_id"])
    if not allowed:
        try:
            expires = int(request.args.get("e", "0"))
        except ValueError:
            expires = 0
        sig = request.args.get("s", "")
        allowed = expires > time.time() and hmac.compare_digest(sig, share_signature(ch, expires))
    if not allowed:
        audit("watch_denied", f"channel={name}")
        abort(404)
    play_until = int(time.time()) + PLAYBACK_TTL
    token = playback_token(name, play_until)
    return render_template("watch.html", ch=ch, src=f"/private/{token}/{play_until}/{name}.m3u8")


@app.route("/studio/admin")
@admin_required
def admin():
    users = db().execute("SELECT id, username, role FROM users ORDER BY username").fetchall()
    events = db().execute("SELECT * FROM events ORDER BY id DESC LIMIT 150").fetchall()
    return render_template("admin.html", users=users, events=events)


@app.route("/studio/admin/users", methods=["POST"])
@admin_required
def create_user():
    username = request.form.get("username", "").strip()
    password = request.form.get("password", "")
    role = "admin" if request.form.get("role") == "admin" else "user"
    if not USERNAME_RE.match(username):
        flash("Usernames: 3-32 chars, letters, digits, . _ -", "error")
    elif len(password) < 12:
        flash("Passwords must be at least 12 characters.", "error")
    else:
        try:
            db().execute("INSERT INTO users (username, pw_hash, role) VALUES (?, ?, ?)",
                         (username, generate_password_hash(password), role))
            db().commit()
            audit("user_create", f"user={username} role={role}")
            flash(f"User {username} created.", "ok")
        except sqlite3.IntegrityError:
            flash("That username is taken.", "error")
    return redirect(url_for("admin"))


@app.route("/studio/admin/users/<int:user_id>/delete", methods=["POST"])
@admin_required
def delete_user(user_id):
    user = db().execute("SELECT * FROM users WHERE id = ?", (user_id,)).fetchone()
    if user is None or user["username"] == "admin":
        abort(400, "This user can't be deleted")
    for ch in db().execute("SELECT name FROM channels WHERE owner_id = ?", (user_id,)).fetchall():
        stop_proc(ch["name"])
        path = os.path.join(VIDEO_DIR, f"{ch['name']}.mp4")
        if os.path.exists(path):
            os.remove(path)
    db().execute("DELETE FROM users WHERE id = ?", (user_id,))
    db().commit()
    audit("user_delete", f"user={user['username']}")
    return redirect(url_for("admin"))


@app.route("/studio/internal/publish-auth")
def publish_auth():
    """Called by nginx-rtmp (on_publish, GET) for every publish attempt.

    Only reachable from localhost: nginx does not proxy /studio/internal/, and
    a request relayed by the reverse proxy would carry X-Forwarded-For.
    """
    if request.remote_addr != "127.0.0.1" or "X-Forwarded-For" in request.headers:
        abort(404)
    name = request.args.get("name", "")
    key = request.args.get("key", "")
    rtmp_app = request.args.get("app", "")
    addr = request.args.get("addr", "")
    ch = db().execute("SELECT * FROM channels WHERE name = ?", (name,)).fetchone()
    ok = (ch is not None
          and rtmp_app == ("private" if ch["private"] else "live")
          and hmac.compare_digest(key, ch["stream_key"]))
    audit("publish_ok" if ok else "publish_denied", f"app={rtmp_app} channel={name}",
          username="rtmp", ip=addr)
    return ("", 200) if ok else ("", 403)


@app.route("/studio/internal/playback-auth")
def playback_auth():
    """nginx auth_request subrequest for every /private/... playlist or segment."""
    if request.remote_addr != "127.0.0.1" or "X-Forwarded-For" in request.headers:
        abort(404)
    m = PLAYBACK_PATH_RE.match(request.headers.get("X-Original-URI", "").split("?", 1)[0])
    if m is None:
        return "", 403
    expires = int(m["exp"])
    if expires < time.time():
        return "", 403
    expected = playback_token(m["chan"], expires)
    return ("", 204) if hmac.compare_digest(m["tok"], expected) else ("", 403)


@app.errorhandler(400)
@app.errorhandler(403)
@app.errorhandler(404)
@app.errorhandler(429)
def http_error(err):
    return render_template("error.html", err=err), err.code


init_db()
threading.Thread(target=supervisor, daemon=True).start()
