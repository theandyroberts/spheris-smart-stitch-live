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
FEEDBACK_DIR = DATA_DIR / "feedback"
FEEDBACK_DIR.mkdir(parents=True, exist_ok=True)

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
    # Tag with current clip number
    shoot = get_shoot()
    entry["clip"] = shoot.get("clip_number", 0)
    fb = get_feedback()
    fb.append(entry)
    save_json(FEEDBACK_FILE, fb)


def archive_feedback():
    """Archive current feedback to a per-clip file and clear the live list."""
    fb = get_feedback()
    if not fb:
        return
    shoot = get_shoot()
    clip_num = shoot.get("clip_number", 0)
    shoot_name = shoot.get("name", "shoot")
    archive = {
        "shoot_name": shoot_name,
        "clip_number": clip_num,
        "archived": datetime.now(timezone.utc).isoformat(),
        "feedback": fb,
    }
    slug = re.sub(r"[^a-z0-9]+", "-", shoot_name.lower()).strip("-")
    filename = f"{slug}_clip{clip_num:03d}.json"
    save_json(FEEDBACK_DIR / filename, archive)
    save_json(FEEDBACK_FILE, [])


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
        stream_active=shoot.get("stream_active", False),
        clip_number=shoot.get("clip_number", 0))


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


@app.route("/api/admin/feedback", methods=["GET"])
def admin_feedback():
    """List archived feedback. Optional ?clip=N to filter by clip."""
    key = request.headers.get("X-Api-Key", "")
    if key != os.environ.get("SPHERIS_ADMIN_KEY", "spheris-admin-dev"):
        abort(403)
    clip_filter = request.args.get("clip")
    archives = []
    for f in sorted(FEEDBACK_DIR.glob("*.json")):
        data = load_json(f, {})
        if clip_filter and str(data.get("clip_number")) != clip_filter:
            continue
        archives.append(data)
    return jsonify(archives)


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
    # Archive previous clip's feedback, then start a new clip
    archive_feedback()
    shoot = get_shoot()
    shoot["stream_active"] = True
    shoot["clip_number"] = shoot.get("clip_number", 0) + 1
    shoot["clip_started"] = datetime.now(timezone.utc).isoformat()
    save_shoot(shoot)
    return "", 200


@app.route("/api/internal/stream-stop", methods=["POST"])
def stream_stop():
    shoot = get_shoot()
    shoot["stream_active"] = False
    save_shoot(shoot)
    return "", 200


# ── View mode tracking ────────────────────────────────────────────────────

VIEWSTATS_FILE = DATA_DIR / "viewstats.json"


def get_viewstats():
    return load_json(VIEWSTATS_FILE, {})


@app.route("/api/viewmode", methods=["POST"])
def report_viewmode():
    """Viewers report their current view mode (flat or 360). Called periodically."""
    session, _ = get_session_from_request()
    if not session:
        abort(401)
    data = request.get_json(silent=True) or {}
    mode = data.get("mode", "flat")
    if mode not in ("flat", "360"):
        mode = "flat"
    stats = get_viewstats()
    email = session["email"]
    if email not in stats:
        stats[email] = {"switches": []}
    prev = stats[email].get("current")
    stats[email]["current"] = mode
    stats[email]["last_seen"] = datetime.now(timezone.utc).isoformat()
    if prev and prev != mode:
        stats[email]["switches"].append({
            "from": prev, "to": mode,
            "at": datetime.now(timezone.utc).isoformat()
        })
    save_json(VIEWSTATS_FILE, stats)
    return jsonify({"ok": True})


@app.route("/api/admin/viewstats", methods=["GET"])
def admin_viewstats():
    """View mode stats for all viewers."""
    key = request.headers.get("X-Api-Key", "")
    if key != os.environ.get("SPHERIS_ADMIN_KEY", "spheris-admin-dev"):
        abort(403)
    stats = get_viewstats()
    flat_count = sum(1 for v in stats.values() if v.get("current") == "flat")
    three60_count = sum(1 for v in stats.values() if v.get("current") == "360")
    return jsonify({
        "flat": flat_count,
        "360": three60_count,
        "viewers": stats
    })


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
<meta name="viewport" content="width=device-width, initial-scale=1, user-scalable=no">
<title>{{ shoot_name }} — Live</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
         background: #000; color: #eee; }
  .header { display: flex; justify-content: space-between; align-items: center;
            padding: 8px 16px; background: #111; position: relative; z-index: 100; }
  .header h1 { font-size: 14px; color: #4a9eff; letter-spacing: 1px; }
  .header .right { display: flex; align-items: center; gap: 12px; }
  .header .user { font-size: 12px; color: #888; }
  .header a { color: #666; font-size: 12px; text-decoration: none; }

  /* View mode toggle */
  .view-toggle { display: flex; background: #222; border-radius: 6px; overflow: hidden;
                 font-size: 12px; }
  .view-toggle button { padding: 4px 12px; border: none; background: transparent;
                        color: #888; cursor: pointer; font-size: 12px;
                        transition: all 0.2s; }
  .view-toggle button.active { background: #4a9eff; color: #fff; }
  .view-toggle button:hover:not(.active) { color: #ccc; }

  /* Flat view */
  .flat-container { width: 100%; background: #000; }
  .flat-container video { width: 100%; display: block; }

  /* 360 view */
  .sphere-container { width: 100%; position: relative; }
  #viewer { width: 100%; display: block; cursor: grab; }
  #viewer:active { cursor: grabbing; }
  .heading-bar { text-align: center; padding: 4px 0; font-size: 12px;
                 color: #888; font-family: 'SF Mono', 'Menlo', monospace;
                 background: #111; }

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

  .hidden { display: none !important; }
</style>
</head>
<body>
<div class="header">
  <h1>SPHERIS 360 — {{ shoot_name }}{% if clip_number %} — Clip {{ clip_number }}{% endif %}</h1>
  <div class="right">
    {% if stream_active %}
    <div class="view-toggle">
      <button id="btn-flat" class="active" onclick="switchView('flat')">Flat</button>
      <button id="btn-360" onclick="switchView('360')">360</button>
    </div>
    <div class="view-toggle">
      <button id="btn-grade" onclick="toggleGrade()">Grade: Off</button>
    </div>
    {% endif %}
    <span class="user">{{ email }} &nbsp; <a href="/logout">logout</a></span>
  </div>
</div>

{% if stream_active %}
<!-- Shared video element (visible in flat mode, hidden texture source in 360 mode) -->
<video id="video" autoplay muted playsinline crossorigin="anonymous"></video>

<!-- Flat view (default) -->
<div class="flat-container" id="flat-view">
  <video id="video-flat" autoplay muted playsinline></video>
</div>

<!-- 360 view (hidden initially) -->
<div class="sphere-container hidden" id="sphere-view">
  <canvas id="viewer"></canvas>
  <div class="heading-bar" id="heading-bar"></div>
</div>
{% else %}
<div class="standby">Waiting for stream to start...</div>
{% endif %}

<div class="feedback-bar">
  <button id="like-btn" onclick="sendLike()">&#x1F44D; Like</button>
  <input id="comment-input" placeholder="Add a note at this timestamp..."
         onkeydown="if(event.key==='Enter')sendComment()">
  <button onclick="sendComment()">Send</button>
</div>

<div class="feedback-list" id="feedback-list"></div>

<script src="https://cdn.jsdelivr.net/npm/hls.js@latest"></script>
<script src="https://cdn.jsdelivr.net/npm/three@0.160.0/build/three.min.js"></script>
<script>
// ── State ──
let currentView = 'flat';
let gradeEnabled = false;
let sphereInitialized = false;
let sphereRenderer, sphereCamera, sphereScene, sphereAnimId;
let sphereMaterial = null;

const video = document.getElementById('video');
const videoFlat = document.getElementById('video-flat');
const canvas = document.getElementById('viewer');
const flatView = document.getElementById('flat-view');
const sphereView = document.getElementById('sphere-view');

// ── HLS setup — attach to both video elements ──
const hlsSrc = '/hls/spheris.m3u8';

function attachHLS(el) {
  if (!el) return;
  if (el.canPlayType('application/vnd.apple.mpegurl')) {
    el.src = hlsSrc;
  } else if (typeof Hls !== 'undefined' && Hls.isSupported()) {
    const hls = new Hls({ liveSyncDuration: 3, liveMaxLatencyDuration: 6 });
    hls.loadSource(hlsSrc);
    hls.attachMedia(el);
  }
}

// Flat video gets HLS immediately
attachHLS(videoFlat);
// Hidden video for Three.js texture — attach when 360 mode activates
let hiddenHLSAttached = false;

// ── View switching ──
function switchView(mode) {
  currentView = mode;
  document.getElementById('btn-flat').classList.toggle('active', mode === 'flat');
  document.getElementById('btn-360').classList.toggle('active', mode === '360');

  if (mode === 'flat') {
    flatView.classList.remove('hidden');
    sphereView.classList.add('hidden');
    // Pause 360 rendering when not visible
    if (sphereAnimId) { cancelAnimationFrame(sphereAnimId); sphereAnimId = null; }
  } else {
    flatView.classList.add('hidden');
    sphereView.classList.remove('hidden');
    if (!sphereInitialized) initSphere();
    else animateSphere();
  }

  // Report view mode to server
  reportViewMode(mode);
}

function reportViewMode(mode) {
  fetch('/api/viewmode', {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({ mode: mode })
  }).catch(() => {});
}

// Report initial mode and periodically
if (video) {
  reportViewMode('flat');
  setInterval(() => reportViewMode(currentView), 30000);
}

// ── Color grade toggle ──
function toggleGrade() {
  gradeEnabled = !gradeEnabled;
  const btn = document.getElementById('btn-grade');
  if (btn) {
    btn.textContent = gradeEnabled ? 'Grade: On' : 'Grade: Off';
    btn.classList.toggle('active', gradeEnabled);
  }
  // Update 360 shader uniform
  if (sphereMaterial) {
    sphereMaterial.uniforms.lutEnabled.value = gradeEnabled ? 1 : 0;
  }
  // For flat view: use a CSS filter approximation (boost contrast + saturation)
  if (videoFlat) {
    videoFlat.style.filter = gradeEnabled
      ? 'contrast(1.4) saturate(1.5) brightness(1.1)'
      : 'none';
  }
}

// ── Three.js 360 viewer (lazy init) ──
let lon = 180, lat = 0, fov = 90;
const fovMin = 30, fovMax = 120;

function initSphere() {
  if (!canvas || !video) return;
  sphereInitialized = true;

  // Attach HLS to hidden video for texture
  if (!hiddenHLSAttached) {
    attachHLS(video);
    hiddenHLSAttached = true;
  }

  sphereScene = new THREE.Scene();
  sphereCamera = new THREE.PerspectiveCamera(fov, canvas.clientWidth / canvas.clientHeight, 0.1, 1000);
  sphereCamera.position.set(0, 0, 0);

  sphereRenderer = new THREE.WebGLRenderer({ canvas: canvas, antialias: true });
  sphereRenderer.setSize(canvas.clientWidth, canvas.clientHeight);
  sphereRenderer.setPixelRatio(window.devicePixelRatio);

  const texture = new THREE.VideoTexture(video);
  texture.minFilter = THREE.LinearFilter;
  texture.magFilter = THREE.LinearFilter;
  texture.colorSpace = THREE.SRGBColorSpace;

  // ShaderMaterial with optional Log3G10/RWG → Rec.709 color grade
  sphereMaterial = new THREE.ShaderMaterial({
    uniforms: {
      map: { value: texture },
      lutEnabled: { value: 0 }
    },
    vertexShader: [
      'varying vec2 vUv;',
      'void main() {',
      '  vUv = uv;',
      '  gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);',
      '}'
    ].join('\\n'),
    fragmentShader: [
      'uniform sampler2D map;',
      'uniform int lutEnabled;',
      'varying vec2 vUv;',
      '',
      '// REDLog3G10 decode',
      'float log3g10ToLinear(float x) {',
      '  float A = 0.091; float B = 0.6; float C = 155.975327;',
      '  if (x <= A) return (x - A) / (B * C * 0.4342945);',  // log10(e)
      '  return (pow(10.0, (x - A) / B) - 1.0) / C;',
      '}',
      '',
      '// Rec.709 OETF',
      'float rec709(float L) {',
      '  if (L < 0.018) return clamp(4.5 * L, 0.0, 1.0);',
      '  return clamp(1.099 * pow(max(L, 0.0), 0.45) - 0.099, 0.0, 1.0);',
      '}',
      '',
      'void main() {',
      '  vec4 tex = texture2D(map, vUv);',
      '  vec3 c = tex.rgb;',
      '  if (lutEnabled == 1) {',
      '    // Decode Log3G10',
      '    float rLin = log3g10ToLinear(c.r);',
      '    float gLin = log3g10ToLinear(c.g);',
      '    float bLin = log3g10ToLinear(c.b);',
      '    // REDWideGamut → Rec.709 matrix',
      '    float r709 = 1.4183*rLin - 0.3209*gLin - 0.0974*bLin;',
      '    float g709 = -0.0913*rLin + 1.1673*gLin - 0.0760*bLin;',
      '    float b709 = -0.0094*rLin - 0.0560*gLin + 1.0654*bLin;',
      '    // Rec.709 OETF',
      '    c = vec3(rec709(r709), rec709(g709), rec709(b709));',
      '  }',
      '  gl_FragColor = vec4(c, 1.0);',
      '}'
    ].join('\\n'),
    side: THREE.BackSide
  });

  const geometry = new THREE.SphereGeometry(500, 64, 32);
  sphereScene.add(new THREE.Mesh(geometry, sphereMaterial));

  // Mouse / touch drag
  let isDragging = false, startX = 0, startY = 0, startLon = 0, startLat = 0;

  canvas.addEventListener('pointerdown', e => {
    isDragging = true;
    startX = e.clientX; startY = e.clientY;
    startLon = lon; startLat = lat;
    canvas.setPointerCapture(e.pointerId);
  });
  canvas.addEventListener('pointermove', e => {
    if (!isDragging) return;
    const sensitivity = fov / 90 * 0.2;
    lon = startLon + (startX - e.clientX) * sensitivity;
    lat = startLat + (e.clientY - startY) * sensitivity;
    lat = Math.max(-85, Math.min(85, lat));
  });
  canvas.addEventListener('pointerup', e => {
    isDragging = false;
    canvas.releasePointerCapture(e.pointerId);
  });

  // Scroll to zoom
  canvas.addEventListener('wheel', e => {
    e.preventDefault();
    fov = Math.max(fovMin, Math.min(fovMax, fov + e.deltaY * 0.05));
    sphereCamera.fov = fov;
    sphereCamera.updateProjectionMatrix();
  }, { passive: false });

  // Touch pinch to zoom
  let lastPinchDist = 0;
  canvas.addEventListener('touchstart', e => {
    if (e.touches.length === 2) {
      const dx = e.touches[0].clientX - e.touches[1].clientX;
      const dy = e.touches[0].clientY - e.touches[1].clientY;
      lastPinchDist = Math.sqrt(dx*dx + dy*dy);
    }
  }, { passive: true });
  canvas.addEventListener('touchmove', e => {
    if (e.touches.length === 2) {
      const dx = e.touches[0].clientX - e.touches[1].clientX;
      const dy = e.touches[0].clientY - e.touches[1].clientY;
      const dist = Math.sqrt(dx*dx + dy*dy);
      fov = Math.max(fovMin, Math.min(fovMax, fov + (lastPinchDist - dist) * 0.1));
      sphereCamera.fov = fov;
      sphereCamera.updateProjectionMatrix();
      lastPinchDist = dist;
    }
  }, { passive: true });

  // Resize
  window.addEventListener('resize', () => {
    if (!sphereRenderer || currentView !== '360') return;
    sphereCamera.aspect = canvas.clientWidth / canvas.clientHeight;
    sphereCamera.updateProjectionMatrix();
    sphereRenderer.setSize(canvas.clientWidth, canvas.clientHeight);
  });

  animateSphere();
}

function animateSphere() {
  sphereAnimId = requestAnimationFrame(animateSphere);
  const phi = THREE.MathUtils.degToRad(90 - lat);
  const theta = THREE.MathUtils.degToRad(lon);
  const target = new THREE.Vector3(
    500 * Math.sin(phi) * Math.cos(theta),
    500 * Math.cos(phi),
    500 * Math.sin(phi) * Math.sin(theta)
  );
  sphereCamera.lookAt(target);

  // Heading display
  const bar = document.getElementById('heading-bar');
  if (bar) {
    let heading = ((lon % 360) + 360) % 360;
    heading = (heading - 180 + 360) % 360;
    bar.textContent = Math.round(heading) + '\u00B0  FoV ' + Math.round(fov) + '\u00B0';
  }

  sphereRenderer.render(sphereScene, sphereCamera);
}

// ── Feedback ──
function getPlaybackTime() {
  const v = currentView === 'flat' ? videoFlat : video;
  return v ? Math.round(v.currentTime * 10) / 10 : null;
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
      if (!list) return;
      list.innerHTML = items.slice(-50).reverse().map(item => {
        const ts = item.timestamp != null ? '@ ' + Math.floor(item.timestamp/60) + ':' + String(Math.floor(item.timestamp%60)).padStart(2,'0') : '';
        if (item.type === 'like') {
          return '<div class="feedback-item"><span class="like-icon">&#x1F44D;</span> ' + item.email + ' ' + ts + ' <span class="meta">' + new Date(item.created).toLocaleTimeString() + '</span></div>';
        }
        return '<div class="feedback-item"><strong>' + item.email + '</strong> ' + ts + ': ' + item.text + ' <span class="meta">' + new Date(item.created).toLocaleTimeString() + '</span></div>';
      }).join('');
    })
    .catch(() => {});
}

loadFeedback();
setInterval(loadFeedback, 5000);

{% if not stream_active %}
setTimeout(() => location.reload(), 10000);
{% endif %}
</script>
</body>
</html>"""


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=5000, debug=True)
