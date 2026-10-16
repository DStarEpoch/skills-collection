#!/usr/bin/env python3
"""Prove this skill package works on this machine, end to end, on a toy film.

It runs the whole pipeline against `examples/tiny/` — parse the plan, render at
480p15, inspect the clips, build subtitles, burn them into the joined cut, and
inspect that too. Nothing is downloaded and nothing outside `examples/tiny/out/`
is written; on success the artifacts are deleted again unless `--keep` is given.

    python scripts/selftest.py
    python scripts/selftest.py --keep --quality h
    python scripts/selftest.py --sub-font "Microsoft YaHei"      # CJK subtitles

Exit code 0 means every stage passed; 1 prints which stage failed. Run this
first on a new machine, then fix the missing piece the report names.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
EXAMPLE = os.path.join(ROOT, "examples", "tiny")
OUT = os.path.join(EXAMPLE, "out")
CLASS_RE = re.compile(r"^class\s+(\w+)\s*\(([^)]*)\)", re.MULTILINE)


def run(label, args, cwd=EXAMPLE):
    """Run one stage, echo its tail, return (ok, output)."""
    print("\n== %s ==" % label)
    print("   $ %s" % " ".join(args))
    proc = subprocess.run(args, cwd=cwd, capture_output=True)
    text = ((proc.stdout or b"") + (proc.stderr or b"")).decode("utf-8", "replace").strip()
    for line in text.splitlines()[-14:]:
        print("   | %s" % line)
    return proc.returncode == 0, text


def validate_plan():
    """Cheapest failure first: the plan and the scene files must agree."""
    plan_path = os.path.join(EXAMPLE, "plan.json")
    with open(plan_path, encoding="utf-8") as handle:
        plan = json.load(handle)
    problems = []
    for scene in plan.get("scenes", []):
        path = os.path.join(EXAMPLE, scene["file"])
        if not os.path.exists(path):
            problems.append("%s: missing %s" % (scene["id"], scene["file"]))
            continue
        with open(path, encoding="utf-8") as handle:
            source = handle.read()
        classes = {name for name, bases in CLASS_RE.findall(source) if "Scene" in bases}
        if scene.get("class") not in classes:
            problems.append("%s: class %s not in %s (found %s)"
                            % (scene["id"], scene.get("class"), scene["file"], sorted(classes)))
        if not (scene.get("narration", {}).get("script") or "").strip():
            problems.append("%s: no narration script" % scene["id"])
    return plan, problems


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--quality", default="l", choices=["l", "m", "h"], help="render quality (default l)")
    parser.add_argument("--keep", action="store_true", help="keep examples/tiny/out afterwards")
    parser.add_argument("--sub-font", default="", help="CJK font for burned subtitles, e.g. Microsoft YaHei")
    parser.add_argument("--sub-margin", type=int, default=40, help="ASS MarginV for subtitles (default 40)")
    args = parser.parse_args()

    print("package   : %s" % ROOT)
    print("example   : %s" % EXAMPLE)
    print("python    : %s" % sys.executable)

    plan, problems = validate_plan()
    if problems:
        print("\nplan      : INVALID")
        for problem in problems:
            print("   ! %s" % problem)
        return 1
    print("plan      : %d scenes, files and classes agree" % len(plan["scenes"]))

    clips = os.path.join(OUT, "clips")
    shutil.rmtree(OUT, ignore_errors=True)

    ok, _ = run("render (one clip per scene)",
                [sys.executable, os.path.join(HERE, "render.py"), "scenes",
                 "--plan", "plan.json", "--out", clips,
                 "--quality", args.quality, "--manifest", os.path.join(OUT, "render-report.json")])
    if not ok:
        print("\nFAILED    : render — read the tail above (LaTeX, a typo in a class name, ...)")
        return 1

    first = os.path.join(clips, plan["scenes"][0]["id"] + ".mp4")
    ok, _ = run("inspect one clip", [sys.executable, os.path.join(HERE, "check_video.py"), first, "--frames", "0"])
    if not ok:
        print("\nFAILED    : check_video on a rendered clip — is ffprobe on PATH?")
        return 1

    subtitles = os.path.join(OUT, "subtitles.srt")
    ok, _ = run("subtitles from the plan",
                [sys.executable, os.path.join(HERE, "make_srt.py"), "plan.json",
                 "--clips", clips, "--out", subtitles])
    if not ok:
        print("\nFAILED    : make_srt")
        return 1

    final = os.path.join(OUT, "tiny.mp4")
    join = [sys.executable, os.path.join(HERE, "assemble.py"), clips, "--manifest", "plan.json", "--out", final]
    if args.sub_font:
        join += ["--burn-subs", subtitles, "--sub-font", args.sub_font, "--sub-margin", str(args.sub_margin)]
    ok, _ = run("join the cut%s" % (" with burned subtitles" if args.sub_font else ""), join)
    if not ok:
        print("\nFAILED    : assemble — is ffmpeg on PATH?")
        return 1

    ok, text = run("inspect the final cut", [sys.executable, os.path.join(HERE, "check_video.py"), final, "--frames", "0"])
    if not ok:
        print("\nFAILED    : check_video on the final cut")
        return 1

    duration = re.search(r"(\d+\.\d+)s", text)
    print("\nselftest  : PASS — %s%s" % (final, ("  (%s)" % duration.group(0)) if duration else ""))
    if not args.sub_font:
        print("note      : subtitles were not burned this run; pass --sub-font for CJK films")
    if not args.keep:
        shutil.rmtree(OUT, ignore_errors=True)
        print("note      : artifacts removed (--keep to inspect them)")
    else:
        print("artifacts : %s" % OUT)
    return 0


if __name__ == "__main__":
    sys.exit(main())
