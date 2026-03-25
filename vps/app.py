"""
Spheris Stream Auth Server
Flask app handling viewer authentication, session management,
and the watch page for HLS streaming.
"""

import json
import os
import re
import secrets
import time
from datetime import datetime, timezone
from pathlib import Path

from flask import (
    Flask, request, redirect, make_response,
    jsonify, render_template_string, abort
)

app = Flask(__name__)
app.secret_key = secrets.token_hex(32)

# ── Config ──────────────────────────────────────────────────────────────────

DATA_DIR = Path("/var/www/stream/data")
DATA_DIR.mkdir(parents=True, exist_ok=True)

SHOOT_FILE = DATA_DIR / "shoot.json"
SESSIONS_FILE = DATA_DIR / "sessions.json"
FEEDBACK_FILE = DATA_DIR / "feedback.json"


def load_json(path, default=None):
    if path.exists():
        return json.loads(path.read_text())
    return default if default is not None else {}


def save_json(path, data):
    path.write_text(json.dumps(data, indent=2, default=str))


# ── Shoot management ────────────────────────────────────────────────────────
# The Mac app (or admin) sets the daily password via API

def get_shoot():
    return load_json(SHOOT_FILE, {
        "password": "spheris2026",
        "name": "Spheris Live Shoot",
        "stream_active": False,
    })


def save_shoot(shoot):
    save_json(SHOOT_FILE, shoot)


# ── Session management ──────────────────────────────────────────────────────

def get_sessions():
    return load_json(SESSIONS_FILE, {})


def save_sessions(sessions):
    save_json(SESSIONS_FILE, sessions)


def create_session(email):
    sessions = get_sessions()
    token = secrets.token_urlsafe(32)
    sessions[token] = {
        "email": email,
        "created": datetime.now(timezone.utc).isoformat(),
        "last_seen": datetime.now(timezone.utc).isoformat(),
        "revoked": False,
    }
    save_sessions(sessions)
    return token


def validate_session(token):
    if not token:
        return None
    sessions = get_sessions()
    session = sessions.get(token)
    if not session or session.get("revoked"):
        return None
    # Update last seen
    session["last_seen"] = datetime.now(timezone.utc).isoformat()
    save_sessions(sessions)
    return session


def get_session_from_request():
    token = request.cookies.get("spheris_session")
    return validate_session(token), token


# ── Feedback ────────────────────────────────────────────────────────────────

def get_feedback():
    return load_json(FEEDBACK_FILE, [])


def add_feedback(entry):
    fb = get_feedback()
    fb.append(entry)
    save_json(FEEDBACK_FILE, fb)


# ── Routes ──────────────────────────────────────────────────────────────────

@app.route("/")
def index():
    session, _ = get_session_from_request()
    if session:
        return redirect("/watch")
    shoot = get_shoot()
    return render_template_string(LOGIN_HTML, shoot_name=shoot.get("name", "Spheris Live"))


@app.route("/login", methods=["POST"])
def login():
    email = request.form.get("email", "").strip().lower()
    password = request.form.get("password", "").strip()
    shoot = get_shoot()

    # Validate email format
    if not re.match(r"^[^@]+@[^@]+\.[^@]+$", email):
        return render_template_string(LOGIN_HTML,
            shoot_name=shoot.get("name", ""),
            error="Please enter a valid email address.")

    # Validate password
    if password != shoot.get("password", ""):
        return render_template_string(LOGIN_HTML,
            shoot_name=shoot.get("name", ""),
            error="Incorrect password.")

    # Create session and set cookie
    token = create_session(email)
    resp = redirect("/watch")
    resp.set_cookie("spheris_session", token, httponly=True, secure=True,
                    samesite="Lax", max_age=86400)  # 24 hours
    return resp


@app.route("/watch")
def watch():
    session, _ = get_session_from_request()
    if not session:
        return redirect("/")
    shoot = get_shoot()
    return render_template_string(WATCH_HTML,
        shoot_name=shoot.get("name", "Spheris Live"),
        email=session["email"],
        stream_active=shoot.get("stream_active", False))


@app.route("/logout")
def logout():
    _, token = get_session_from_request()
    if token:
        sessions = get_sessions()
        if token in sessions:
            sessions[token]["revoked"] = True
            save_sessions(sessions)
    resp = redirect("/")
    resp.delete_cookie("spheris_session")
    return resp


# ── Feedback API ────────────────────────────────────────────────────────────

@app.route("/api/feedback", methods=["GET"])
def list_feedback():
    session, _ = get_session_from_request()
    if not session:
        abort(401)
    return jsonify(get_feedback())


@app.route("/api/feedback", methods=["POST"])
def post_feedback():
    session, _ = get_session_from_request()
    if not session:
        abort(401)
    data = request.get_json(silent=True) or {}
    entry = {
        "id": secrets.token_hex(8),
        "email": session["email"],
        "type": data.get("type", "comment"),  # "like" or "comment"
        "text": data.get("text", ""),
        "timestamp": data.get("timestamp"),  # playback position in seconds
        "created": datetime.now(timezone.utc).isoformat(),
    }
    add_feedback(entry)
    return jsonify(entry), 201


# ── Admin API (called from Mac app) ────────────────────────────────────────

@app.route("/api/admin/shoot", methods=["POST"])
def admin_set_shoot():
    """Set shoot name and password. Called from the Mac app."""
    key = request.headers.get("X-Api-Key", "")
    if key != os.environ.get("SPHERIS_ADMIN_KEY", "spheris-admin-dev"):
        abort(403)
    data = request.get_json()
    shoot = get_shoot()
    if "password" in data:
        shoot["password"] = data["password"]
    if "name" in data:
        shoot["name"] = data["name"]
    save_shoot(shoot)
    return jsonify({"ok": True})


@app.route("/api/admin/sessions", methods=["GET"])
def admin_list_sessions():
    """List active sessions. Called from dashboard."""
    key = request.headers.get("X-Api-Key", "")
    if key != os.environ.get("SPHERIS_ADMIN_KEY", "spheris-admin-dev"):
        abort(403)
    sessions = get_sessions()
    active = [
        {"email": s["email"], "last_seen": s["last_seen"], "token": t[:8] + "..."}
        for t, s in sessions.items() if not s.get("revoked")
    ]
    return jsonify(active)


@app.route("/api/admin/revoke", methods=["POST"])
def admin_revoke():
    """Revoke a session by email."""
    key = request.headers.get("X-Api-Key", "")
    if key != os.environ.get("SPHERIS_ADMIN_KEY", "spheris-admin-dev"):
        abort(403)
    data = request.get_json()
    email = data.get("email", "").lower()
    sessions = get_sessions()
    revoked = 0
    for s in sessions.values():
        if s["email"] == email and not s.get("revoked"):
            s["revoked"] = True
            revoked += 1
    save_sessions(sessions)
    return jsonify({"revoked": revoked})


# ── Internal nginx auth check ───────────────────────────────────────────────

@app.route("/api/internal/auth-check")
def auth_check():
    """Called by nginx auth_request for HLS segment access."""
    session, _ = get_session_from_request()
    if session:
        return "", 200
    return "", 401


@app.route("/api/internal/stream-start", methods=["POST"])
def stream_start():
    shoot = get_shoot()
    shoot["stream_active"] = True
    save_shoot(shoot)
    return "", 200


@app.route("/api/internal/stream-stop", methods=["POST"])
def stream_stop():
    shoot = get_shoot()
    shoot["stream_active"] = False
    save_shoot(shoot)
    return "", 200


# ── HTML Templates ──────────────────────────────────────────────────────────

LOGIN_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{{ shoot_name }}</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
         background: #111; color: #eee; display: flex; justify-content: center;
         align-items: center; min-height: 100vh; }
  .card { background: #1a1a1a; border-radius: 12px; padding: 40px;
          width: 100%; max-width: 400px; }
  h1 { font-size: 20px; margin-bottom: 8px; }
  .subtitle { color: #888; font-size: 14px; margin-bottom: 24px; }
  label { display: block; font-size: 13px; color: #aaa; margin-bottom: 4px; }
  input { width: 100%; padding: 10px 12px; border-radius: 8px; border: 1px solid #333;
          background: #222; color: #eee; font-size: 15px; margin-bottom: 16px; }
  input:focus { outline: none; border-color: #4a9eff; }
  button { width: 100%; padding: 12px; border-radius: 8px; border: none;
           background: #4a9eff; color: white; font-size: 15px; font-weight: 600;
           cursor: pointer; }
  button:hover { background: #3a8eef; }
  .error { color: #ff6b6b; font-size: 13px; margin-bottom: 12px; }
  .logo { text-align: center; margin-bottom: 24px; font-size: 28px; letter-spacing: 2px;
          font-weight: 700; color: #4a9eff; }
</style>
</head>
<body>
<div class="card">
  <div class="logo">SPHERIS 360</div>
  <h1>{{ shoot_name }}</h1>
  <p class="subtitle">Enter your email and shoot password to watch the live stream.</p>
  {% if error %}<p class="error">{{ error }}</p>{% endif %}
  <form method="POST" action="/login">
    <label for="email">Email</label>
    <input type="email" id="email" name="email" placeholder="you@example.com" required>
    <label for="password">Shoot Password</label>
    <input type="password" id="password" name="password" placeholder="Enter password" required>
    <button type="submit">Join Stream</button>
  </form>
</div>
</body>
</html>"""

WATCH_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{{ shoot_name }} — Live</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
         background: #000; color: #eee; }
  .header { display: flex; justify-content: space-between; align-items: center;
            padding: 8px 16px; background: #111; }
  .header h1 { font-size: 14px; color: #4a9eff; letter-spacing: 1px; }
  .header .user { font-size: 12px; color: #888; }
  .header a { color: #666; font-size: 12px; text-decoration: none; }
  .video-container { width: 100%; background: #000; position: relative; }
  video { width: 100%; height: auto; aspect-ratio: 2/1; object-fit: contain; display: block; }
  .standby { display: flex; justify-content: center; align-items: center;
             height: 50vh; color: #666; font-size: 18px; }
  .feedback-bar { display: flex; padding: 8px 16px; background: #111; gap: 8px; }
  .feedback-bar button { padding: 8px 16px; border-radius: 8px; border: none;
                         background: #222; color: #eee; font-size: 14px; cursor: pointer; }
  .feedback-bar button:hover { background: #333; }
  .feedback-bar button.liked { background: #4a9eff; }
  .feedback-bar input { flex: 1; padding: 8px 12px; border-radius: 8px; border: 1px solid #333;
                        background: #222; color: #eee; font-size: 14px; }
  .feedback-list { padding: 8px 16px; max-height: 200px; overflow-y: auto; }
  .feedback-item { padding: 6px 0; border-bottom: 1px solid #1a1a1a; font-size: 13px; }
  .feedback-item .meta { color: #666; font-size: 11px; }
  .feedback-item .like-icon { color: #4a9eff; }
</style>
</head>
<body>
<div class="header">
  <h1>SPHERIS 360 — {{ shoot_name }}</h1>
  <span class="user">{{ email }} &nbsp; <a href="/logout">logout</a></span>
</div>

<div class="video-container">
  {% if stream_active %}
  <video id="video" controls autoplay muted playsinline></video>
  {% else %}
  <div class="standby">Waiting for stream to start...</div>
  {% endif %}
</div>

<div class="feedback-bar">
  <button id="like-btn" onclick="sendLike()">&#x1F44D; Like</button>
  <input id="comment-input" placeholder="Add a note at this timestamp..."
         onkeydown="if(event.key==='Enter')sendComment()">
  <button onclick="sendComment()">Send</button>
</div>

<div class="feedback-list" id="feedback-list"></div>

<script src="https://cdn.jsdelivr.net/npm/hls.js@latest"></script>
<script>
// HLS player setup
const video = document.getElementById('video');
if (video) {
  const src = '/hls/spheris.m3u8';
  if (video.canPlayType('application/vnd.apple.mpegurl')) {
    // Safari — native HLS
    video.src = src;
  } else if (typeof Hls !== 'undefined' && Hls.isSupported()) {
    // Other browsers — hls.js
    const hls = new Hls({ liveSyncDuration: 3, liveMaxLatencyDuration: 6 });
    hls.loadSource(src);
    hls.attachMedia(video);
  }
}

function getPlaybackTime() {
  return video ? Math.round(video.currentTime * 10) / 10 : null;
}

function sendLike() {
  fetch('/api/feedback', {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({ type: 'like', timestamp: getPlaybackTime() })
  });
  const btn = document.getElementById('like-btn');
  btn.classList.add('liked');
  setTimeout(() => btn.classList.remove('liked'), 1000);
}

function sendComment() {
  const input = document.getElementById('comment-input');
  const text = input.value.trim();
  if (!text) return;
  fetch('/api/feedback', {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({ type: 'comment', text: text, timestamp: getPlaybackTime() })
  });
  input.value = '';
  loadFeedback();
}

function loadFeedback() {
  fetch('/api/feedback')
    .then(r => r.json())
    .then(items => {
      const list = document.getElementById('feedback-list');
      list.innerHTML = items.slice(-50).reverse().map(item => {
        const ts = item.timestamp != null ? `@ ${Math.floor(item.timestamp/60)}:${String(Math.floor(item.timestamp%60)).padStart(2,'0')}` : '';
        if (item.type === 'like') {
          return `<div class="feedback-item"><span class="like-icon">&#x1F44D;</span> ${item.email} ${ts} <span class="meta">${new Date(item.created).toLocaleTimeString()}</span></div>`;
        }
        return `<div class="feedback-item"><strong>${item.email}</strong> ${ts}: ${item.text} <span class="meta">${new Date(item.created).toLocaleTimeString()}</span></div>`;
      }).join('');
    })
    .catch(() => {});
}

// Poll feedback every 5 seconds
loadFeedback();
setInterval(loadFeedback, 5000);

// Auto-refresh page if stream not active (check every 10s)
{% if not stream_active %}
setTimeout(() => location.reload(), 10000);
{% endif %}
</script>
</body>
</html>"""


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=5000, debug=True)
