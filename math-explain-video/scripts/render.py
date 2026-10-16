#!/usr/bin/env python3
"""Render every scene of a math explainer, one clip per scene, with retries.

    python render.py scenes --plan plan.json --out out/scenes --quality l
    python render.py scenes --out out/scenes --quality h --only scene-03 --retries 1
    python render.py scenes --plan plan.json --dry-run

Each scene becomes its own clip, named after the scene id, so the assembler and
the reviewer can talk about `scene-03.mp4` instead of a hash. A failed render
never stops the run: the error tail is captured per scene, the scene is retried
(--retries times), and the JSON report lists exactly which scenes still fail so
the next fix round can be aimed at them.

Manim is invoked as `python -m manim`, which is stable across versions; pass
--manim to point at another entry. stdout/stderr are decoded as UTF-8
(PYTHONUTF8=1 for the child) because Manim prints box characters that garble
under a legacy Windows code page.
"""

import argparse
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import time

CLASS_RE = re.compile(r"^class\s+(\w+)\s*\(([^)]*)\)", re.MULTILINE)
READY_RE = re.compile(r"File ready at '([^']+)'")


def discover_classes(path):
    """Scene classes defined in a file, without importing Manim."""
    try:
        with open(path, encoding="utf-8") as handle:
            source = handle.read()
    except OSError:
        return []
    found = []
    for name, bases in CLASS_RE.findall(source):
        if "Scene" in bases:
            found.append(name)
    return found


def plan_scenes(plan_path, folder):
    with open(plan_path, encoding="utf-8") as handle:
        plan = json.load(handle)
    scenes = []
    for scene in plan.get("scenes", []):
        file_path = scene.get("file") or ""
        if file_path and not os.path.isabs(file_path):
            file_path = os.path.join(os.path.dirname(os.path.abspath(plan_path)), file_path)
        if not file_path or not os.path.exists(file_path):
            candidate = os.path.join(folder, (scene.get("id", "") + ".py").replace("-", "_"))
            file_path = file_path if file_path and os.path.exists(file_path) else candidate
        scenes.append({
            "id": scene.get("id") or os.path.splitext(os.path.basename(file_path))[0],
            "file": file_path,
            "classes": [scene["class"]] if scene.get("class") else discover_classes(file_path),
            "planned_seconds": scene.get("duration"),
        })
    return scenes


def folder_scenes(folder):
    scenes = []
    for name in sorted(os.listdir(folder)):
        if not name.endswith(".py") or name.startswith("_"):
            continue
        path = os.path.join(folder, name)
        classes = discover_classes(path)
        if classes:
            scenes.append({"id": os.path.splitext(name)[0].replace("_", "-"), "file": path, "classes": classes, "planned_seconds": None})
    return scenes


def find_clip(media_dir, output_name):
    matches = []
    for root, _dirs, files in os.walk(media_dir):
        for name in files:
            if name == output_name + ".mp4":
                matches.append(os.path.join(root, name))
    if not matches:
        return None
    matches.sort(key=lambda path: os.path.getmtime(path), reverse=True)
    return matches[0]


def probe_duration(path):
    proc = subprocess.run(
        [os.environ.get("FFPROBE", "ffprobe"), "-v", "error", "-show_entries", "format=duration",
         "-of", "default=noprint_wrappers=1:nokey=1", path],
        capture_output=True)
    try:
        return round(float(proc.stdout.decode("utf-8", "replace").strip()), 2)
    except ValueError:
        return None


def main():
    parser = argparse.ArgumentParser(description="Render every scene of a math explainer.")
    parser.add_argument("folder", help="folder holding the scene .py files")
    parser.add_argument("--plan", default="", help="plan JSON (scene ids, files, classes and target durations)")
    parser.add_argument("--out", default="out/scenes", help="where the one-clip-per-scene files land")
    parser.add_argument("--quality", default="l", choices=["l", "m", "h", "p", "k"],
                        help="l=854x480@15 (draft), m=1280x720@30, h=1920x1080@60, p=2560x1440@60, k=3840x2160@60 (default without -q is h)")
    parser.add_argument("--fps", type=float, default=0,
                        help="override the preset frame rate (e.g. 30 for 1080p30; the presets have no such option)")
    parser.add_argument("--retries", type=int, default=2, help="extra attempts per scene after the first failure")
    parser.add_argument("--timeout", type=float, default=900, help="seconds per attempt (default 900)")
    parser.add_argument("--only", default="", help="render only scenes whose id contains this text")
    parser.add_argument("--dry-run", action="store_true", help="print the commands, render nothing")
    parser.add_argument("--no-cache", action="store_true", help="pass --disable_caching for a deterministic take")
    parser.add_argument("--keep-latex", action="store_true",
                        help="pass --no_latex_cleanup so media/Tex/*.log survives when a formula fails")
    parser.add_argument("--media-dir", default="", help="Manim media dir (default <out>/../manim-media)")
    parser.add_argument("--manim", default="",
                        help="manim entry point as a command string, such as 'uv run manim' or a full path "
                             "(default: this interpreter, -m manim)")
    parser.add_argument("--manifest", default="", help="write a per-scene JSON report here")
    args = parser.parse_args()

    folder = os.path.abspath(args.folder)
    if not os.path.isdir(folder):
        sys.exit("no such folder: %s" % folder)
    out_dir = os.path.abspath(args.out)
    os.makedirs(out_dir, exist_ok=True)
    media_dir = os.path.abspath(args.media_dir) if args.media_dir else os.path.join(os.path.dirname(out_dir), "manim-media")

    scenes = plan_scenes(args.plan, folder) if args.plan else folder_scenes(folder)
    if args.only:
        scenes = [scene for scene in scenes if args.only in scene["id"]]
    if not scenes:
        sys.exit("no scenes found in %s" % folder)

    if not shutil.which(os.environ.get("FFPROBE", "ffprobe")):
        print("note      : ffprobe not on PATH, durations will be unknown")

    base = shlex.split(args.manim, posix=False) if args.manim else [sys.executable, "-m", "manim"]
    base = [part.strip('"') for part in base] or [sys.executable, "-m", "manim"]
    env = dict(os.environ, PYTHONUTF8="1", PYTHONIOENCODING="utf-8")
    report = []
    failures = 0

    for scene in scenes:
        classes = scene["classes"]
        if not classes:
            # Never call manim without a scene name: a file with several scenes
            # (or one it cannot see) makes the CLI wait on stdin, which looks
            # exactly like a hang.
            print("FAIL %-28s no Scene class found in %s (not rendering)" % (scene["id"], scene["file"]))
            failures += 1
            report.append({"id": scene["id"], "status": "failed", "attempts": 0, "render_seconds": 0.0,
                           "clip": None, "duration": None, "planned_seconds": scene.get("planned_seconds"),
                           "duration_ratio": None,
                           "error_tail": "no Scene subclass found; fix the class name or pass --plan with an explicit class"})
            continue
        for class_name in classes:
            media_name = scene["id"] if len(classes) == 1 else "%s-%s" % (scene["id"], class_name)
            target = os.path.join(out_dir, media_name + ".mp4")
            cmd = base + ["render", "-q" + args.quality, "--format=mp4", "--media_dir", media_dir,
                          "-o", media_name, "-v", "WARNING", "--progress_bar", "none"]
            if args.fps:
                cmd += ["--fps", str(args.fps)]
            if args.keep_latex:
                cmd.append("--no_latex_cleanup")
            if args.no_cache:
                cmd.append("--disable_caching")
            cmd.append(scene["file"])
            cmd.append(class_name)
            if args.dry_run:
                print(" ".join(cmd))
                continue

            attempts = 0
            status = "failed"
            error_tail = ""
            started = time.time()
            while attempts <= args.retries:
                attempts += 1
                try:
                    # stdin=DEVNULL: manim asks on stdin in a few paths (several
                    # scenes in one file, an illegal -n), and a captured stdin
                    # turns that prompt into an apparent hang.
                    proc = subprocess.run(cmd, capture_output=True, timeout=args.timeout, env=env,
                                          stdin=subprocess.DEVNULL)
                    code = proc.returncode
                    output = (proc.stdout or b"") + (proc.stderr or b"")
                except subprocess.TimeoutExpired:
                    code = -1
                    output = ("timed out after %.0f s" % args.timeout).encode()
                text = output.decode("utf-8", "replace")
                if code == 0:
                    # A zero exit code is not proof: manim also exits 0 for an
                    # illegal -n/--resolution, and a misspelled construct() gives
                    # a black screen with exit code 0. Require the file it says it
                    # wrote, non-empty, with a real duration.
                    ready = READY_RE.search(text)
                    clip = None
                    if ready and os.path.exists(ready.group(1)) and os.path.getsize(ready.group(1)) > 0:
                        clip = ready.group(1)
                    else:
                        clip = find_clip(media_dir, media_name)
                    if clip and os.path.getsize(clip) > 0:
                        shutil.copy2(clip, target)
                        duration = probe_duration(target)
                        if duration and duration > 0:
                            status = "ok"
                            break
                        error_tail = "clip exists but ffprobe reads no duration: %s" % target
                    else:
                        error_tail = ("manim exited 0 but wrote no usable %s.mp4 under %s "
                                      "(check the scene name, and that construct() is spelled correctly)" % (media_name, media_dir))
                else:
                    lines = [line for line in text.splitlines() if line.strip()]
                    error_tail = "\n".join(lines[-14:])
                if attempts <= args.retries:
                    print("retry %d/%d for %s" % (attempts, args.retries, media_name))
            spent = round(time.time() - started, 1)
            duration = probe_duration(target) if status == "ok" else None
            planned = scene.get("planned_seconds")
            drift = None
            if duration and planned:
                drift = round(duration / float(planned), 2)
            flag = "ok " if status == "ok" else "FAIL"
            print("%s %-28s %6.1fs render  %s clip%s" % (
                flag, media_name, spent,
                ("%.2fs" % duration) if duration else "   ?  ",
                ("  (planned %ss, ratio %s)" % (planned, drift)) if drift else ""))
            if status != "ok":
                failures += 1
                for line in error_tail.splitlines():
                    print("      | %s" % line)
            report.append({
                "id": media_name, "status": status, "attempts": attempts, "render_seconds": spent,
                "clip": target if status == "ok" else None, "duration": duration,
                "planned_seconds": planned, "duration_ratio": drift,
                "error_tail": None if status == "ok" else error_tail,
            })

    if args.dry_run:
        return 0
    if args.manifest:
        with open(args.manifest, "w", encoding="utf-8") as handle:
            json.dump({"scenes": report}, handle, ensure_ascii=False, indent=2)
        print("report    : %s" % args.manifest)
    total = sum(item["duration"] or 0 for item in report)
    print("summary   : %d rendered, %d failed, %.1fs total footage" % (
        len(report) - failures, failures, total))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
