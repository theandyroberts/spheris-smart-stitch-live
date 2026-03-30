#!/usr/bin/env python3
"""
Spheris 360 Auto-Calibration Tool

9-camera 360° rig calibration with lens library integration.
Detects features, matches overlapping pairs, runs bundle adjustment
with locked focal lengths from known lens data, outputs calibration JSON
for the Swift real-time stitcher + PTGui .pts project file.

Usage:
    python calibrate.py --input ./Roll02_Clip09/ --output config/calibration.json
    python calibrate.py --input ./Roll02_Clip09/ --list-lenses
    python calibrate.py --input ./Roll02_Clip09/ --lens-horizontal "Sigma 14mm Art"
"""

import argparse
import json
import logging
import math
import os
import shutil
import subprocess
import sys
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

import cv2
import numpy as np

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("calibrate")

# ── Sensor ───────────────────────────────────────────────────────────────────

SENSOR_WIDTH_MM = 22.56
SENSOR_HEIGHT_MM = 11.88

# ── Camera rig topology ─────────────────────────────────────────────────────

CAMERAS = [
    {"id": "A", "type": "horizontal", "yaw": -81.7,  "pitch": 10.1,  "roll": -0.7},
    {"id": "B", "type": "horizontal", "yaw": -27.1,  "pitch":  7.9,  "roll":  0.2},
    {"id": "C", "type": "horizontal", "yaw":  26.2,  "pitch": 10.5,  "roll": -1.1},
    {"id": "D", "type": "horizontal", "yaw":  80.7,  "pitch":  7.5,  "roll": -1.5},
    {"id": "E", "type": "horizontal", "yaw": 134.8,  "pitch":  9.9,  "roll":  0.1},
    {"id": "F", "type": "horizontal", "yaw": -136.1, "pitch":  8.5,  "roll": -1.7},
    {"id": "G", "type": "upward",     "yaw": -83.5,  "pitch": 54.8,  "roll":  0.0},
    {"id": "H", "type": "upward",     "yaw":  26.6,  "pitch": 54.8,  "roll":  0.0},
    {"id": "J", "type": "upward",     "yaw": 145.0,  "pitch": 54.8,  "roll":  0.0},
]
CAM_INDEX = {c["id"]: i for i, c in enumerate(CAMERAS)}

OVERLAP_PAIRS = [
    ("A", "B"), ("B", "C"), ("C", "D"), ("D", "E"), ("E", "F"), ("F", "A"),
    ("G", "A"), ("G", "B"), ("G", "F"),
    ("H", "B"), ("H", "C"), ("H", "D"),
    ("J", "D"), ("J", "E"), ("J", "F"),
    ("G", "H"), ("H", "J"), ("J", "G"),
]

MIN_INLIER_MATCHES = 15
LOWE_RATIO = 0.7
RANSAC_REPROJ_THRESH = 5.0
OUTPUT_SIZE = (3840, 1920)

# ── Lens library ────────────────────────────────────────────────────────────

def load_lens_library():
    lib_path = Path(__file__).parent / "lens_library.json"
    if not lib_path.exists():
        log.error(f"Lens library not found at {lib_path}")
        sys.exit(1)
    with open(lib_path) as f:
        data = json.load(f)
    lenses = {lens["lens_name"]: lens for lens in data["lenses"]}
    return lenses


def find_lens(lenses, name):
    if name in lenses:
        return lenses[name]
    # Fuzzy match
    name_lower = name.lower()
    for key, lens in lenses.items():
        if name_lower in key.lower() or name_lower in lens["full_name"].lower():
            return lens
    return None


def focal_mm_to_px(focal_mm, image_width):
    return focal_mm * image_width / SENSOR_WIDTH_MM


def focal_px_to_mm(focal_px, image_width):
    return focal_px * SENSOR_WIDTH_MM / image_width


def list_lenses(lenses):
    print("\nAvailable lenses (RED Komodo S35, {:.2f}mm x {:.2f}mm sensor):".format(
        SENSOR_WIDTH_MM, SENSOR_HEIGHT_MM))
    print("-" * 80)
    for lens in sorted(lenses.values(), key=lambda l: l["focal_length_mm"]):
        fpx = focal_mm_to_px(lens["focal_length_mm"], 2048)
        print(f"  {lens['lens_name']:<28s} {lens['focal_length_mm']:5.1f}mm  "
              f"hFOV={lens['fov_h_deg']:5.1f}°  vFOV={lens['fov_v_deg']:5.1f}°  "
              f"f_px={fpx:.1f}")
        print(f"    {lens['full_name']}")
    print()


# ── Frame extraction ────────────────────────────────────────────────────────

def ensure_frames(input_dir, frame_num=100, force=False):
    """Extract a specific frame from each MOV. Skips if JPEGs already exist unless force=True."""
    movs = sorted(Path(input_dir).glob("*.mov"))
    jpgs = sorted(Path(input_dir).glob("*.jpg"))

    if not force:
        cam_letters = set(c["id"] for c in CAMERAS)
        existing = set()
        for jpg in jpgs:
            for letter in cam_letters:
                if jpg.name.upper().startswith(letter + "0"):
                    existing.add(letter)
        if existing == cam_letters:
            log.info("JPEG frames already exist, skipping extraction")
            return

    if not movs:
        log.error(f"No MOV files found in {input_dir}")
        sys.exit(1)

    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        log.error("ffmpeg not found — needed for frame extraction")
        sys.exit(1)

    log.info(f"Extracting frame {frame_num} from {len(movs)} MOV files...")
    for mov in movs:
        out_jpg = mov.with_suffix(".jpg")
        cmd = [ffmpeg, "-nostdin", "-i", str(mov), "-vf", f"select=eq(n\\,{frame_num})",
               "-vframes", "1", "-q:v", "2", str(out_jpg), "-y"]
        try:
            result = subprocess.run(
                cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                text=True, timeout=120
            )
            if result.returncode != 0:
                log.warning(f"  ffmpeg failed for {mov.name}: {result.stderr[-200:]}")
            else:
                log.info(f"  Extracted {out_jpg.name}")
        except subprocess.TimeoutExpired:
            log.warning(f"  ffmpeg timed out for {mov.name} (>120s)")
        except Exception as e:
            log.warning(f"  ffmpeg error for {mov.name}: {e}")


# ── Image loading ───────────────────────────────────────────────────────────

def load_images(input_dir):
    images = []
    image_filenames = []
    for cam in CAMERAS:
        letter = cam["id"]
        img = None
        found_name = None
        for fname in sorted(os.listdir(input_dir)):
            if not fname.upper().startswith(letter + "0"):
                continue
            if not fname.lower().endswith((".jpg", ".jpeg", ".tiff", ".tif", ".png")):
                continue
            path = os.path.join(input_dir, fname)
            img = cv2.imread(path)
            if img is not None:
                found_name = fname
                break
        if img is None:
            log.error(f"Could not find image for camera {letter} in {input_dir}")
            sys.exit(1)
        log.info(f"  {letter}: {found_name} ({img.shape[1]}x{img.shape[0]})")
        images.append(img)
        image_filenames.append(found_name)
    return images, image_filenames


# ── Feature detection & matching ────────────────────────────────────────────

def detect_features(images):
    finder = cv2.SIFT_create(nfeatures=10000, contrastThreshold=0.02, edgeThreshold=15)
    features = []
    for i, img in enumerate(images):
        feat = cv2.detail.computeImageFeatures2(finder, img)
        feat.img_idx = i
        features.append(feat)
        log.info(f"  {CAMERAS[i]['id']}: {len(feat.getKeypoints())} keypoints")
    return features


def match_features(features):
    n = len(features)
    bf = cv2.BFMatcher(cv2.NORM_L2)

    pairwise_matches = []
    for i in range(n):
        for j in range(n):
            mi = cv2.detail.MatchesInfo()
            mi.src_img_idx = i
            mi.dst_img_idx = j
            if i == j:
                mi.confidence = 1.0
                mi.num_inliers = 0
                mi.H = np.eye(3, dtype=np.float64)
            else:
                mi.confidence = 0.0
                mi.num_inliers = 0
            pairwise_matches.append(mi)

    pair_results = []

    for id_a, id_b in OVERLAP_PAIRS:
        i, j = CAM_INDEX[id_a], CAM_INDEX[id_b]
        desc_a = features[i].descriptors
        desc_b = features[j].descriptors
        kps_a = features[i].getKeypoints()
        kps_b = features[j].getKeypoints()

        if desc_a is None or desc_b is None or len(kps_a) < 2 or len(kps_b) < 2:
            pair_results.append((id_a, id_b, 0, 0))
            continue

        da = np.float32(desc_a.get() if isinstance(desc_a, cv2.UMat) else desc_a)
        db = np.float32(desc_b.get() if isinstance(desc_b, cv2.UMat) else desc_b)

        raw_matches = bf.knnMatch(da, db, k=2)
        good = []
        for m_pair in raw_matches:
            if len(m_pair) == 2 and m_pair[0].distance < LOWE_RATIO * m_pair[1].distance:
                good.append(m_pair[0])

        if len(good) < 4:
            pair_results.append((id_a, id_b, len(good), 0))
            continue

        pts_a = np.float32([kps_a[m.queryIdx].pt for m in good])
        pts_b = np.float32([kps_b[m.trainIdx].pt for m in good])
        H, mask = cv2.findHomography(pts_a, pts_b, cv2.RANSAC, RANSAC_REPROJ_THRESH)

        if H is None or mask is None:
            pair_results.append((id_a, id_b, len(good), 0))
            continue

        inlier_mask = mask.ravel().astype(bool)
        num_inliers = int(inlier_mask.sum())

        if num_inliers < MIN_INLIER_MATCHES:
            log.info(f"  {id_a}↔{id_b}: {num_inliers} inliers / {len(good)} matches [WEAK]")
            pair_results.append((id_a, id_b, len(good), num_inliers))
            continue

        confidence = num_inliers / (8 + 0.3 * len(good))

        # Build MatchesInfo for forward and reverse
        for direction in ["fwd", "rev"]:
            dmatches = []
            inliers_byte = []
            for k_idx, m in enumerate(good):
                dm = cv2.DMatch()
                if direction == "fwd":
                    dm.queryIdx, dm.trainIdx = m.queryIdx, m.trainIdx
                else:
                    dm.queryIdx, dm.trainIdx = m.trainIdx, m.queryIdx
                dm.distance = m.distance
                dm.imgIdx = 0
                dmatches.append(dm)
                inliers_byte.append(1 if inlier_mask[k_idx] else 0)

            if direction == "fwd":
                idx = i * n + j
                H_use = H.astype(np.float64)
            else:
                idx = j * n + i
                H_use = np.linalg.inv(H).astype(np.float64) if abs(np.linalg.det(H)) > 1e-10 else np.eye(3, dtype=np.float64)

            pairwise_matches[idx].matches = tuple(dmatches)
            pairwise_matches[idx].inliers_mask = tuple(inliers_byte)
            pairwise_matches[idx].num_inliers = num_inliers
            pairwise_matches[idx].confidence = confidence
            pairwise_matches[idx].H = H_use

        pair_results.append((id_a, id_b, len(good), num_inliers))
        log.info(f"  {id_a}↔{id_b}: {num_inliers} inliers / {len(good)} matches (conf={confidence:.3f})")

    # Summary
    log.info("── Match summary ─────────────────────")
    ok = 0
    for id_a, id_b, nm, ni in pair_results:
        status = "OK" if ni >= MIN_INLIER_MATCHES else "WEAK" if ni > 0 else "NONE"
        if ni >= MIN_INLIER_MATCHES:
            ok += 1
        log.info(f"  {id_a}↔{id_b}: {ni:4d} inliers / {nm:4d} matches  [{status}]")
    log.info(f"  {ok}/{len(OVERLAP_PAIRS)} pairs with sufficient matches")

    return pairwise_matches, pair_results


# ── Rotation helpers ────────────────────────────────────────────────────────

def ypr_to_rotation_matrix(yaw_deg, pitch_deg, roll_deg):
    y, p, r = math.radians(yaw_deg), math.radians(pitch_deg), math.radians(roll_deg)
    Ry = np.array([[math.cos(y),0,math.sin(y)],[0,1,0],[-math.sin(y),0,math.cos(y)]], dtype=np.float64)
    Rx = np.array([[1,0,0],[0,math.cos(p),-math.sin(p)],[0,math.sin(p),math.cos(p)]], dtype=np.float64)
    Rz = np.array([[math.cos(r),-math.sin(r),0],[math.sin(r),math.cos(r),0],[0,0,1]], dtype=np.float64)
    return Ry @ Rx @ Rz


def rotation_matrix_to_ypr(R):
    pitch = math.asin(-np.clip(R[1, 2], -1, 1))
    if abs(math.cos(pitch)) > 1e-6:
        yaw = math.atan2(R[0, 2], R[2, 2])
        roll = math.atan2(R[1, 0], R[1, 1])
    else:
        yaw = math.atan2(-R[2, 0], R[0, 0])
        roll = 0
    return math.degrees(yaw), math.degrees(pitch), math.degrees(roll)


# ── Connected components ────────────────────────────────────────────────────

def find_connected_components(pair_results, n_cameras, threshold):
    parent = list(range(n_cameras))
    def find(x):
        while parent[x] != x: parent[x] = parent[parent[x]]; x = parent[x]
        return x
    def union(a, b):
        ra, rb = find(a), find(b)
        if ra != rb: parent[ra] = rb
    for id_a, id_b, _, ni in pair_results:
        if ni >= threshold:
            union(CAM_INDEX[id_a], CAM_INDEX[id_b])
    comps = defaultdict(list)
    for i in range(n_cameras): comps[find(i)].append(i)
    return list(comps.values())


# ── Bundle adjustment ───────────────────────────────────────────────────────

def build_initial_cameras(images, horiz_lens, sky_lens):
    cameras = []
    for i, cam in enumerate(CAMERAS):
        lens = sky_lens if cam["type"] == "upward" else horiz_lens
        cp = cv2.detail.CameraParams()
        cp.aspect = 1.0
        cp.focal = focal_mm_to_px(lens["focal_length_mm"], images[i].shape[1])
        cp.ppx = images[i].shape[1] / 2.0
        cp.ppy = images[i].shape[0] / 2.0
        cp.R = ypr_to_rotation_matrix(cam["yaw"], cam["pitch"], cam["roll"]).astype(np.float32)
        cp.t = np.zeros((3, 1), dtype=np.float64)
        cameras.append(cp)
    return cameras


def run_bundle_adjustment(features, pairwise_matches, cameras, images, pair_results,
                          horiz_lens, sky_lens):
    n = len(cameras)

    # Only BA horizontal cameras — sky cameras placed by geometry
    horiz_indices = [i for i in range(n) if CAMERAS[i]["type"] == "horizontal"]
    horiz_comps = find_connected_components(
        [(a, b, nm, ni) for a, b, nm, ni in pair_results
         if CAM_INDEX[a] in horiz_indices and CAM_INDEX[b] in horiz_indices],
        n, MIN_INLIER_MATCHES
    )
    horiz_comps = [c for c in horiz_comps if len(c) > 1 and all(i in horiz_indices for i in c)]

    if not horiz_comps:
        log.warning("No connected horizontal pairs — using initial rig geometry")
        return cameras

    largest = max(horiz_comps, key=len)
    largest_set = set(largest)
    log.info(f"Running BA on horizontal ring: {[CAMERAS[i]['id'] for i in sorted(largest)]}")

    # Build sub-problem
    old_to_new = {old: new for new, old in enumerate(sorted(largest))}
    new_to_old = {v: k for k, v in old_to_new.items()}
    sub_n = len(largest)

    sub_features = [features[new_to_old[i]] for i in range(sub_n)]
    for i in range(sub_n): sub_features[i].img_idx = i

    sub_pairwise = []
    for i in range(sub_n):
        for j in range(sub_n):
            orig = pairwise_matches[new_to_old[i] * n + new_to_old[j]]
            mi = cv2.detail.MatchesInfo()
            mi.src_img_idx, mi.dst_img_idx = i, j
            mi.confidence = orig.confidence
            mi.num_inliers = orig.num_inliers
            mi.H = np.copy(orig.H) if orig.H is not None else np.eye(3, dtype=np.float64)
            if orig.matches is not None and len(orig.matches) > 0:
                mi.matches = orig.matches
                mi.inliers_mask = orig.inliers_mask
            sub_pairwise.append(mi)

    sub_cameras = []
    for i in range(sub_n):
        c = cameras[new_to_old[i]]
        cp = cv2.detail.CameraParams()
        cp.R, cp.t = np.copy(c.R), np.copy(c.t)
        cp.focal, cp.ppx, cp.ppy, cp.aspect = c.focal, c.ppx, c.ppy, c.aspect
        sub_cameras.append(cp)

    # BA with LOCKED focal length — only refine rotation
    for adj_cls, name in [(cv2.detail.BundleAdjusterReproj, "Reproj"),
                           (cv2.detail.BundleAdjusterRay, "Ray")]:
        adjuster = adj_cls()
        adjuster.setConfThresh(0.1)
        refine_mask = np.zeros((3, 3), dtype=np.uint8)
        # All zeros = lock all intrinsics, only refine rotation
        adjuster.setRefinementMask(refine_mask)
        adjuster.setTermCriteria((cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 1000, 1e-8))

        attempt = []
        for c in sub_cameras:
            cp = cv2.detail.CameraParams()
            cp.R, cp.t = np.copy(c.R), np.copy(c.t)
            cp.focal, cp.ppx, cp.ppy, cp.aspect = c.focal, c.ppx, c.ppy, c.aspect
            attempt.append(cp)

        success, refined = adjuster.apply(sub_features, sub_pairwise, attempt)
        log.info(f"  BundleAdjuster{name}: {'converged' if success else 'failed'}")
        if success:
            sub_cameras_refined = refined
            break
    else:
        log.warning("Both adjusters failed — using last result")
        sub_cameras_refined = refined

    # Wave correction on horizontal cameras — forces the horizon level
    rmats = [np.copy(c.R).astype(np.float32) for c in sub_cameras_refined]
    cv2.detail.waveCorrect(rmats, cv2.detail.WAVE_CORRECT_HORIZ)

    # Check if wave correction flipped the pitch direction.
    # Compare corrected pitches against the initial rig pitches.
    init_pitches = [CAMERAS[new_to_old[i]]["pitch"] for i in range(sub_n)]
    corrected_pitches = [rotation_matrix_to_ypr(rm.astype(np.float64))[1] for rm in rmats]
    # Compute mean signed pitch error vs initial
    pitch_error = float(np.mean([cp - ip for cp, ip in zip(corrected_pitches, init_pitches)]))
    if abs(pitch_error) > 15:
        log.info(f"  Wave correction shifted pitch by {pitch_error:+.1f}° — compensating")
        # Apply a global pitch correction to bring pitches back near initial values
        for i in range(len(rmats)):
            y, p, r = rotation_matrix_to_ypr(rmats[i].astype(np.float64))
            p_corrected = p - pitch_error
            rmats[i] = ypr_to_rotation_matrix(y, p_corrected, r).astype(np.float32)

    # ── Orientation constraints ──
    # On a rigid rig, each camera's orientation should stay close to the
    # initial geometry. The good hand-tuned calibration deviates by at most
    # ~1-2° in any axis. Allow some room but prevent wild optimizer drift.
    MAX_YAW_DEG = 5.0    # per-camera yaw deviation from initial (after global offset removed)
    MAX_PITCH_DEG = 5.0
    MAX_ROLL_DEG = 3.0

    # First compute the median yaw offset (global rotation) so we only
    # clamp per-camera deviations, not the global shift
    yaw_offsets = []
    for i in range(len(rmats)):
        y, _, _ = rotation_matrix_to_ypr(rmats[i].astype(np.float64))
        init_yaw = CAMERAS[new_to_old[i]]["yaw"]
        offset = ((y - init_yaw + 180) % 360) - 180
        yaw_offsets.append(offset)
    median_yaw_offset = float(np.median(yaw_offsets))

    clamped_count = 0
    for i in range(len(rmats)):
        y, p, r = rotation_matrix_to_ypr(rmats[i].astype(np.float64))
        init_yaw = CAMERAS[new_to_old[i]]["yaw"]
        init_pitch = CAMERAS[new_to_old[i]]["pitch"]
        init_roll = CAMERAS[new_to_old[i]]["roll"]
        cam_id = CAMERAS[new_to_old[i]]["id"]
        needs_clamp = False

        # Clamp yaw (relative to global offset — only constrain per-camera deviation)
        y_out = y
        per_cam_yaw_offset = ((y - init_yaw + 180) % 360) - 180 - median_yaw_offset
        if abs(per_cam_yaw_offset) > MAX_YAW_DEG:
            clamped_offset = max(-MAX_YAW_DEG, min(MAX_YAW_DEG, per_cam_yaw_offset))
            y_out = init_yaw + median_yaw_offset + clamped_offset
            log.info(f"  Camera {cam_id}: yaw clamped {y:.1f}° → {y_out:.1f}° "
                     f"(per-cam offset {per_cam_yaw_offset:+.1f}° → {clamped_offset:+.1f}°)")
            needs_clamp = True

        # Clamp roll
        r_out = r
        if abs(r - init_roll) > MAX_ROLL_DEG:
            r_out = init_roll + max(-MAX_ROLL_DEG, min(MAX_ROLL_DEG, r - init_roll))
            log.info(f"  Camera {cam_id}: roll clamped {r:.1f}° → {r_out:.1f}°")
            needs_clamp = True

        # Clamp pitch
        p_out = p
        if abs(p - init_pitch) > MAX_PITCH_DEG:
            p_out = init_pitch + max(-MAX_PITCH_DEG, min(MAX_PITCH_DEG, p - init_pitch))
            log.info(f"  Camera {cam_id}: pitch clamped {p:.1f}° → {p_out:.1f}°")
            needs_clamp = True

        if needs_clamp:
            rmats[i] = ypr_to_rotation_matrix(y_out, p_out, r_out).astype(np.float32)
            clamped_count += 1
    if clamped_count:
        log.info(f"  Orientation clamped on {clamped_count}/{sub_n} cameras "
                 f"(global yaw offset: {median_yaw_offset:+.1f}°)")

    for i, c in enumerate(sub_cameras_refined): c.R = rmats[i]

    # Merge back
    result = list(cameras)
    for ni, cr in enumerate(sub_cameras_refined):
        result[new_to_old[ni]] = cr

    # ── Normalize global rotation ──
    # BA only recovers relative rotations — the absolute yaw reference is arbitrary.
    # Wave correction can introduce a large global yaw shift. We normalize by
    # computing the median yaw offset from the initial rig geometry and removing it,
    # so the output stays centered close to the initial camera positions.
    horiz_offsets = []
    for i in sorted(largest):
        actual_yaw, _, _ = rotation_matrix_to_ypr(result[i].R.astype(np.float64))
        initial_yaw = CAMERAS[i]["yaw"]
        offset = ((actual_yaw - initial_yaw + 180) % 360) - 180
        horiz_offsets.append(offset)
    global_yaw_shift = float(np.median(horiz_offsets))

    if abs(global_yaw_shift) > 10:
        log.info(f"  Removing global yaw shift: {global_yaw_shift:.1f}°")
        for i in sorted(largest):
            yaw, pitch, roll = rotation_matrix_to_ypr(result[i].R.astype(np.float64))
            result[i].R = ypr_to_rotation_matrix(yaw - global_yaw_shift, pitch, roll).astype(np.float32)
    else:
        global_yaw_shift = 0

    # Compute per-horizontal-camera yaw offsets introduced by BA + wave correction
    horiz_yaw_offsets = {}
    for i in sorted(largest):
        actual_yaw, _, _ = rotation_matrix_to_ypr(result[i].R.astype(np.float64))
        initial_yaw = CAMERAS[i]["yaw"]
        offset = ((actual_yaw - initial_yaw + 180) % 360) - 180
        horiz_yaw_offsets[CAMERAS[i]["id"]] = offset
    log.info(f"  BA yaw offsets: {', '.join(f'{k}={v:.1f}°' for k, v in horiz_yaw_offsets.items())}")

    # Per-sky-camera offset from its overlapping horizontal neighbors
    sky_neighbor_map = {
        "G": ["A", "B", "F"],
        "H": ["B", "C", "D"],
        "J": ["D", "E", "F"],
    }
    sky_yaw_offsets = {}
    for sky_id, neighbors in sky_neighbor_map.items():
        neighbor_offsets = [horiz_yaw_offsets[n] for n in neighbors if n in horiz_yaw_offsets]
        if neighbor_offsets:
            sky_yaw_offsets[sky_id] = float(np.mean(neighbor_offsets))
        else:
            sky_yaw_offsets[sky_id] = float(np.mean(list(horiz_yaw_offsets.values())))
    log.info(f"  Sky yaw offsets: {', '.join(f'{k}={v:.1f}°' for k, v in sky_yaw_offsets.items())}")

    # Place sky cameras with overlap, applying the yaw offset
    horiz_focal = cameras[horiz_indices[0]].focal  # locked, all same
    sky_focal = focal_mm_to_px(sky_lens["focal_length_mm"], images[0].shape[1])
    h_img = images[0].shape[0]
    horiz_vfov_half = math.degrees(math.atan(h_img / (2 * horiz_focal)))
    sky_vfov_half = math.degrees(math.atan(h_img / (2 * sky_focal)))
    sky_overlap = 5.0
    sky_pitch = horiz_vfov_half + sky_vfov_half - sky_overlap
    log.info(f"  Horiz vFOV/2={horiz_vfov_half:.1f}°, Sky vFOV/2={sky_vfov_half:.1f}°")
    log.info(f"  Sky pitch={sky_pitch:.1f}° (overlap ~{sky_overlap}°)")

    for i in range(n):
        if CAMERAS[i]["type"] == "upward":
            cam_id = CAMERAS[i]["id"]
            adjusted_yaw = CAMERAS[i]["yaw"] + sky_yaw_offsets.get(cam_id, 0)
            cp = cv2.detail.CameraParams()
            cp.aspect = 1.0
            cp.focal = sky_focal
            cp.ppx = images[i].shape[1] / 2.0
            cp.ppy = images[i].shape[0] / 2.0
            cp.R = ypr_to_rotation_matrix(adjusted_yaw, sky_pitch, 0).astype(np.float32)
            cp.t = np.zeros((3, 1), dtype=np.float64)
            result[i] = cp

    for i, c in enumerate(result):
        yaw, pitch, roll = rotation_matrix_to_ypr(c.R.astype(np.float64))
        fov_h = 2 * math.degrees(math.atan(images[i].shape[1] / (2 * c.focal)))
        src = "BA" if i in largest_set else "SKY"
        log.info(f"  {CAMERAS[i]['id']}: f={c.focal:.1f}px fov_h={fov_h:.1f}° "
                 f"yaw={yaw:.1f}° pitch={pitch:.1f}° roll={roll:.1f}° [{src}]")

    # ── Validate BA result ──
    # Check that horizontal cameras maintained their relative order and spacing.
    # The rig has 6 cameras at ~60° intervals. BA should only shift them by
    # a global rotation + small per-camera adjustments, NOT swap their positions.
    horiz_yaws_initial = [CAMERAS[i]["yaw"] for i in range(n) if CAMERAS[i]["type"] == "horizontal"]
    horiz_yaws_result = []
    for i in range(n):
        if CAMERAS[i]["type"] != "horizontal":
            continue
        yaw, _, _ = rotation_matrix_to_ypr(result[i].R.astype(np.float64))
        horiz_yaws_result.append(yaw)

    # Check pairwise angular distances between consecutive horizontal cameras.
    # Initial spacing is ~60°. If any pair deviates by more than 25° from
    # the initial spacing, the BA likely converged to a wrong solution.
    max_spacing_error = 0
    for k in range(len(horiz_yaws_initial)):
        k2 = (k + 1) % len(horiz_yaws_initial)
        init_gap = ((horiz_yaws_initial[k2] - horiz_yaws_initial[k] + 180) % 360) - 180
        result_gap = ((horiz_yaws_result[k2] - horiz_yaws_result[k] + 180) % 360) - 180
        spacing_error = abs(((result_gap - init_gap + 180) % 360) - 180)
        max_spacing_error = max(max_spacing_error, spacing_error)

    if max_spacing_error > 30:
        log.error(f"  BA VALIDATION FAILED: camera spacing error = {max_spacing_error:.1f}° "
                  f"(max allowed 25°)")
        log.error(f"  The bundle adjustment converged to a wrong rotational solution.")
        log.error(f"  Try: (1) use --quality full, (2) pick a better-lit frame with "
                  f"--frame N, or (3) use a frame with more visual detail in the "
                  f"overlap regions between cameras.")
        log.error(f"  Falling back to initial rig geometry with BA yaw offsets only.")

        # Fall back: apply only a global yaw rotation (median offset) to the initial poses
        offsets = []
        for k in range(len(horiz_yaws_initial)):
            off = ((horiz_yaws_result[k] - horiz_yaws_initial[k] + 180) % 360) - 180
            offsets.append(off)
        # Check if offsets are consistent (all ~same = global rotation, fine)
        # or scattered (camera swap, bad)
        offset_std = float(np.std(offsets))
        if offset_std < 15:
            # Consistent global offset — this is actually OK, just a rotation
            median_offset = float(np.median(offsets))
            log.info(f"  Global yaw offset: {median_offset:.1f}° (std={offset_std:.1f}°) — "
                     f"applying as global rotation")
            for i in range(n):
                init_yaw = CAMERAS[i]["yaw"]
                init_pitch = CAMERAS[i]["pitch"]
                init_roll = CAMERAS[i]["roll"]
                if CAMERAS[i]["type"] == "upward":
                    adjusted_yaw = init_yaw + median_offset
                    result[i].R = ypr_to_rotation_matrix(adjusted_yaw, sky_pitch, 0).astype(np.float32)
                else:
                    adjusted_yaw = init_yaw + median_offset
                    result[i].R = ypr_to_rotation_matrix(adjusted_yaw, init_pitch, init_roll).astype(np.float32)
        else:
            log.error(f"  Yaw offsets inconsistent (std={offset_std:.1f}°) — "
                      f"using initial geometry unchanged")
            result = build_initial_cameras(images, horiz_lens, sky_lens)

    return result


# ── Output ──────────────────────────────────────────────────────────────────

def write_calibration_json(cameras_refined, images, image_filenames,
                            horiz_lens, sky_lens, output_path):
    cam_entries = []
    for i, c in enumerate(cameras_refined):
        h, w = images[i].shape[:2]
        yaw, pitch, roll = rotation_matrix_to_ypr(c.R.astype(np.float64))
        cam_def = CAMERAS[i]
        is_sky = cam_def["type"] == "upward"
        lens = sky_lens if is_sky else horiz_lens
        fov_h = 2 * math.degrees(math.atan(w / (2 * c.focal)))
        fov_v = 2 * math.degrees(math.atan(h / (2 * c.focal)))

        cam_entries.append({
            "id": cam_def["id"],
            "image_file": os.path.splitext(image_filenames[i])[0],
            "group": cam_def["type"],
            "lens": lens["lens_name"],
            "image_size": [w, h],
            "projection": "rectilinear",
            "focal_length_px": round(float(c.focal), 2),
            "focal_length_mm": lens["focal_length_mm"],
            "fov_h_deg": round(fov_h, 2),
            "fov_v_deg": round(fov_v, 2),
            "yaw_deg": round(yaw, 4),
            "pitch_deg": round(pitch, 4),
            "roll_deg": round(roll, 4),
            "distortion": {
                "a": lens["typical_distortion"].get("a", 0.0),
                "b": lens["typical_distortion"].get("b", 0.0),
                "c": lens["typical_distortion"].get("c", 0.0),
                "d": lens["typical_distortion"].get("d", 0.0),
                "e": lens["typical_distortion"].get("e", 0.0),
            },
            "principal_point": [round(float(c.ppx), 2), round(float(c.ppy), 2)],
        })

    output = {
        "rig_name": "Spheris 9-Cam Ground Rig",
        "created": datetime.now(timezone.utc).isoformat(),
        "tool": "spheris-calibrate v0.2",
        "sensor": {"width_mm": SENSOR_WIDTH_MM, "height_mm": SENSOR_HEIGHT_MM},
        "output_projection": "equirectangular",
        "output_size": list(OUTPUT_SIZE),
        "cameras": cam_entries,
    }

    os.makedirs(os.path.dirname(output_path) or ".", exist_ok=True)
    with open(output_path, "w") as f:
        json.dump(output, f, indent=2)
    log.info(f"Calibration written to {output_path}")
    return output


def write_ptgui_pts(cameras_refined, images, image_filenames, output_path):
    ptgui_images = []
    for i, c in enumerate(cameras_refined):
        h, w = images[i].shape[:2]
        yaw, pitch, roll = rotation_matrix_to_ypr(c.R.astype(np.float64))
        fov_h = 2 * math.degrees(math.atan(w / (2 * c.focal)))
        ptgui_images.append({
            "filename": image_filenames[i],
            "width": w, "height": h, "include": True,
            "lenstype": "rectilinear",
            "hfov": round(fov_h, 4),
            "yaw": round(yaw, 4), "pitch": round(pitch, 4), "roll": round(roll, 4),
            "a": 0.0, "b": 0.0, "c": 0.0, "d": 0, "e": 0,
        })
    pts = {
        "ptguiversion": "12.0", "projectformat": 5,
        "project": {
            "outputsize": {"w": OUTPUT_SIZE[0], "h": OUTPUT_SIZE[1]},
            "projection": "equirectangular", "hfov": 360.0, "vfov": 180.0,
        },
        "imagegroups": [{
            "images": ptgui_images,
            "lens": {"lenstype": "rectilinear",
                     "hfov": ptgui_images[0]["hfov"] if ptgui_images else 90.0,
                     "a": 0.0, "b": 0.0, "c": 0.0},
            "size": {"w": ptgui_images[0]["width"], "h": ptgui_images[0]["height"]} if ptgui_images else {},
        }],
    }
    pts_path = output_path.replace(".json", ".pts")
    with open(pts_path, "w") as f:
        json.dump(pts, f, indent=2)
    log.info(f"PTGui project written to {pts_path}")


# ── Preview stitch ──────────────────────────────────────────────────────────

def generate_preview_stitch(cameras_refined, images, output_dir, quality="full"):
    """quality: 'fast' (~1s, 50% scale, feather) or 'full' (~3min, native, multi-band)"""
    log.info(f"Generating preview stitch ({quality} quality)...")

    if quality == "fast":
        scale = 0.5
        warp_imgs, warp_cams = [], []
        for img, cam in zip(images, cameras_refined):
            warp_imgs.append(cv2.resize(img, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA))
            pc = cv2.detail.CameraParams()
            pc.R, pc.t = np.copy(cam.R), np.copy(cam.t)
            pc.focal = cam.focal * scale
            pc.ppx, pc.ppy, pc.aspect = cam.ppx * scale, cam.ppy * scale, cam.aspect
            warp_cams.append(pc)
    else:
        warp_imgs, warp_cams = images, cameras_refined

    focals = [c.focal for c in warp_cams]
    warper_scale = float(sorted(focals)[len(focals) // 2])
    warper = cv2.PyRotationWarper("spherical", warper_scale)

    corners, warped_images, warped_masks, sizes = [], [], [], []
    for i, (img, cam) in enumerate(zip(warp_imgs, warp_cams)):
        K = cam.K().astype(np.float32)
        R = cam.R.astype(np.float32)
        corner, warped = warper.warp(img, K, R, cv2.INTER_LINEAR, cv2.BORDER_REFLECT)
        mask = np.ones(img.shape[:2], dtype=np.uint8) * 255
        _, wmask = warper.warp(mask, K, R, cv2.INTER_NEAREST, cv2.BORDER_CONSTANT)
        corners.append(corner); warped_images.append(warped)
        warped_masks.append(wmask); sizes.append((warped.shape[1], warped.shape[0]))
        log.info(f"  {CAMERAS[i]['id']}: warped {warped.shape[1]}x{warped.shape[0]}")

    # Exposure compensation
    comp_type = cv2.detail.EXPOSURE_COMPENSATOR_GAIN if quality == "fast" else cv2.detail.EXPOSURE_COMPENSATOR_CHANNELS_BLOCKS
    compensator = cv2.detail.ExposureCompensator_createDefault(comp_type)
    compensator.feed(corners, warped_images, warped_masks)
    for i in range(len(warped_images)):
        compensator.apply(i, corners[i], warped_images[i], warped_masks[i])

    if quality == "full":
        # DP seam finding
        seam_finder = cv2.detail.DpSeamFinder("COLOR_GRAD")
        ss = min(1.0, 400.0 / max(s[0] for s in sizes))
        log.info(f"  Seam finding at {ss:.2f}x...")
        si, sm, sc = [], [], []
        for i in range(len(warped_images)):
            si.append(cv2.resize(warped_images[i], None, fx=ss, fy=ss, interpolation=cv2.INTER_AREA) if ss < 1 else warped_images[i].copy())
            sm.append(cv2.resize(warped_masks[i], None, fx=ss, fy=ss, interpolation=cv2.INTER_NEAREST) if ss < 1 else warped_masks[i].copy())
            sc.append((int(corners[i][0] * ss), int(corners[i][1] * ss)))
        seam_finder.find(si, sc, sm)
        for i in range(len(warped_masks)):
            mf = cv2.resize(sm[i], (warped_masks[i].shape[1], warped_masks[i].shape[0]), interpolation=cv2.INTER_NEAREST) if ss < 1 else sm[i]
            warped_masks[i] = cv2.bitwise_and(warped_masks[i], mf)
        log.info("  Seam finding complete")

    dst_roi = cv2.detail.resultRoi(corners, sizes)
    if quality == "fast":
        blender = cv2.detail.FeatherBlender(0.02)
    else:
        blender = cv2.detail.MultiBandBlender(0, 7)
    blender.prepare(dst_roi)
    for i in range(len(warped_images)):
        blender.feed(warped_images[i].astype(np.int16), warped_masks[i], corners[i])

    result, _ = blender.blend(None, None)
    result = np.clip(result, 0, 255).astype(np.uint8)

    jq = 95 if quality == "fast" else 98
    path = os.path.join(output_dir, "calibration_preview.jpg")
    cv2.imwrite(path, result, [cv2.IMWRITE_JPEG_QUALITY, jq])
    log.info(f"Preview saved to {path} ({result.shape[1]}x{result.shape[0]})")


# ── Main ────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Spheris 360 Auto-Calibration")
    parser.add_argument("--input", help="Directory with 9 camera frames or MOVs")
    parser.add_argument("--output", default=None, help="Output calibration JSON (auto-named into config/library/ if omitted)")
    parser.add_argument("--library-dir", default="config/library", help="Library directory for auto-named outputs")
    parser.add_argument("--lens-horizontal", default="Laowa 12mm Cine", help="Lens name for horizontal cameras")
    parser.add_argument("--lens-upward", default="Laowa 9mm Cine", help="Lens name for upward cameras")
    parser.add_argument("--custom-lens-horizontal", help="Custom lens as 'focal_mm,fov_h_deg'")
    parser.add_argument("--custom-lens-upward", help="Custom lens as 'focal_mm,fov_h_deg'")
    parser.add_argument("--list-lenses", action="store_true", help="List available lenses and exit")
    parser.add_argument("--frame", type=int, default=100, help="Frame number to extract from MOVs (default: 100)")
    parser.add_argument("--quality", choices=["fast", "full"], default="full", help="Preview quality")
    parser.add_argument("--no-preview", action="store_true", help="Skip preview stitch")
    parser.add_argument("--verbose", "-v", action="store_true")
    args = parser.parse_args()

    lenses = load_lens_library()

    if args.list_lenses:
        list_lenses(lenses)
        return

    if not args.input:
        parser.error("--input is required (unless --list-lenses)")

    if args.verbose:
        log.setLevel(logging.DEBUG)

    # Resolve lenses
    def resolve_lens(name_arg, custom_arg, label):
        if custom_arg:
            parts = custom_arg.split(",")
            fmm, fov_h = float(parts[0]), float(parts[1])
            fov_v = 2 * math.degrees(math.atan(SENSOR_HEIGHT_MM / (2 * fmm)))
            return {
                "lens_name": f"Custom {fmm}mm",
                "full_name": f"Custom {fmm}mm",
                "focal_length_mm": fmm,
                "fov_h_deg": fov_h,
                "fov_v_deg": round(fov_v, 1),
                "projection": "rectilinear",
                "typical_distortion": {"a": 0.0, "b": 0.0, "c": 0.0, "d": 0.0, "e": 0.0},
            }
        lens = find_lens(lenses, name_arg)
        if not lens:
            log.error(f"Lens '{name_arg}' not found. Use --list-lenses to see options.")
            sys.exit(1)
        return lens

    horiz_lens = resolve_lens(args.lens_horizontal, args.custom_lens_horizontal, "horizontal")
    sky_lens = resolve_lens(args.lens_upward, args.custom_lens_upward, "upward")

    # Auto-generate output path if not specified
    if args.output is None:
        os.makedirs(args.library_dir, exist_ok=True)
        # Use roll/clip from input directory name + MMDD date
        clip_name = Path(args.input).resolve().name  # e.g. "Roll02_Clip020"
        date_str = datetime.now().strftime("%m%d")
        base = f"{clip_name}_{date_str}_{args.quality}"
        # Avoid overwriting existing files: append _1, _2, etc.
        candidate = os.path.join(args.library_dir, f"{base}.json")
        seq = 1
        while os.path.exists(candidate):
            candidate = os.path.join(args.library_dir, f"{base}_{seq}.json")
            seq += 1
        args.output = candidate

    log.info("═══ Spheris 360 Auto-Calibration ═══")
    log.info(f"Input: {args.input}")
    log.info(f"Output: {args.output}")
    log.info(f"Horizontal lens: {horiz_lens['lens_name']} ({horiz_lens['focal_length_mm']}mm, {horiz_lens['fov_h_deg']}° hFOV)")
    log.info(f"Upward lens:     {sky_lens['lens_name']} ({sky_lens['focal_length_mm']}mm, {sky_lens['fov_h_deg']}° hFOV)")

    # Step 0: Extract frames
    force_extract = args.frame != 100  # re-extract if using a non-default frame
    ensure_frames(args.input, frame_num=args.frame, force=force_extract)

    # Step 1: Load
    log.info("── Loading images ──")
    images, image_filenames = load_images(args.input)

    # Step 2: Features
    log.info("── Detecting features (SIFT) ──")
    features = detect_features(images)

    # Step 3: Match
    log.info("── Matching features ──")
    pairwise_matches, pair_results = match_features(features)

    # Step 4: Initial cameras
    log.info("── Initializing cameras ──")
    cameras = build_initial_cameras(images, horiz_lens, sky_lens)

    # Step 5: Bundle adjustment (locked focal)
    log.info("── Bundle adjustment (rotation only, focal locked) ──")
    cameras_refined = run_bundle_adjustment(
        features, pairwise_matches, cameras, images, pair_results,
        horiz_lens, sky_lens
    )

    # Step 6: Write outputs
    output_dir = os.path.dirname(args.output) or "."
    write_calibration_json(cameras_refined, images, image_filenames,
                           horiz_lens, sky_lens, args.output)
    write_ptgui_pts(cameras_refined, images, image_filenames, args.output)

    # Copy to legacy config/calibration.json as current default
    legacy_path = os.path.join(os.path.dirname(args.library_dir), "calibration.json")
    try:
        shutil.copy2(args.output, legacy_path)
        log.info(f"Also copied to {legacy_path}")
    except Exception as e:
        log.warning(f"Could not copy to legacy path: {e}")

    # Step 7: Preview
    if not args.no_preview:
        generate_preview_stitch(cameras_refined, images, output_dir, quality=args.quality)

    log.info("═══ Calibration complete ═══")


if __name__ == "__main__":
    main()
