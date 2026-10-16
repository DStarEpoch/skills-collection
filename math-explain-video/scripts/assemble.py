#!/usr/bin/env python3
"""Join rendered scene clips into the final explainer video.

    python assemble.py out/scenes --out out/final.mp4
    python assemble.py out/scenes --out out/final.mp4 --audio voice.mp3 --burn-subs subs.srt
    python assemble.py out/scenes --out out/final.mp4 --fps 30 --width 1920 --height 1080

Clips that already share codec, size and frame rate are joined without
re-encoding (fast, lossless). Any mismatch switches the whole join to one
re-encode at a common size and frame rate, which is what you want after mixing
quality presets or aspect ratios.

Order is taken from a manifest when given (--manifest plan.json, scene order as
in the plan), otherwise from the sorted file names. Prints the resulting
duration and size so the caller can compare against the plan.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys

FFMPEG = os.environ.get("FFMPEG", "ffmpeg")
FFPROBE = os.environ.get("FFPROBE", "ffprobe")


def need(binary):
    if shutil.which(binary) is None:
        sys.exit("missing binary: %s (set FFMPEG / FFPROBE or add it to PATH)" % binary)


def run(cmd):
    return subprocess.run(cmd, capture_output=True)


def probe(path):
    proc = run([FFPROBE, "-v", "error", "-print_format", "json", "-show_streams", "-show_format", path])
    if proc.returncode != 0:
        sys.exit("ffprobe failed on %s: %s" % (path, proc.stderr.decode("utf-8", "replace").strip()))
    return json.loads(proc.stdout.decode("utf-8-sig"))


def video_of(info):
    for stream in info.get("streams", []):
        if stream.get("codec_type") == "video":
            return stream
    return None


def fps_of(stream):
    text = stream.get("r_frame_rate") or "0/0"
    try:
        num, den = text.split("/")
        return round(float(num) / float(den), 3) if float(den) else 0.0
    except (ValueError, ZeroDivisionError):
        return 0.0


def collect(folder, manifest, exclude=(), only=None, include_all=False):
    skip = {os.path.abspath(path) for path in exclude}
    if manifest:
        with open(manifest, encoding="utf-8") as handle:
            plan = json.load(handle)
        scenes = plan.get("scenes", plan if isinstance(plan, list) else [])
        clips = []
        for scene in scenes:
            name = scene.get("clip") or scene.get("file") or scene.get("id")
            if not name:
                continue
            path = name if os.path.isabs(name) else os.path.join(folder, name)
            if os.path.exists(path) and os.path.abspath(path) not in skip:
                clips.append(path)
            else:
                print("note      : plan lists %s but no such clip" % path)
        if clips:
            return clips
        print("note      : manifest produced no clips, falling back to the folder")
    found = []
    for root, _dirs, files in os.walk(folder):
        for name in sorted(files):
            if name.lower().endswith((".mp4", ".mov", ".mkv")):
                path = os.path.join(root, name)
                if only and only not in name:
                    continue
                if os.path.abspath(path) in skip:
                    continue
                found.append(path)
    found = sorted(found)
    if not include_all:
        # a previous join dropped in the same folder is not a scene: keep it out
        scenes_only = [path for path in found if not os.path.basename(path).lower().startswith("final")]
        if len(scenes_only) != len(found) and scenes_only:
            print("note      : ignoring %d joined file(s) named final* in %s" % (
                len(found) - len(scenes_only), folder))
            found = scenes_only
    return found


def main():
    parser = argparse.ArgumentParser(description="Join scene clips into the final video.")
    parser.add_argument("folder", help="folder holding the rendered scene clips")
    parser.add_argument("--out", required=True, help="final video path")
    parser.add_argument("--manifest", default="", help="plan JSON whose scene order defines the cut order")
    parser.add_argument("--audio", default="", help="optional narration or music track for the whole video")
    parser.add_argument("--burn-subs", default="", help="optional .srt/.ass subtitle file to burn in")
    parser.add_argument("--sub-font", default="", help="font name for burned subtitles (CJK needs this, e.g. Microsoft YaHei)")
    parser.add_argument("--sub-margin", type=int, default=0,
                        help="raise burned subtitles this many pixels from the bottom, to clear scene content")
    parser.add_argument("--include-all", action="store_true", help="also treat final*.mp4 in the folder as a clip")
    parser.add_argument("--fps", type=float, default=0, help="force this frame rate on the join")
    parser.add_argument("--width", type=int, default=0, help="force this width (keeps the aspect, even-rounded)")
    parser.add_argument("--height", type=int, default=0, help="force this height")
    parser.add_argument("--crf", type=int, default=18, help="quality for a re-encode (default 18)")
    parser.add_argument("--force-encode", action="store_true", help="re-encode even when the clips match")
    args = parser.parse_args()

    need(FFMPEG)
    need(FFPROBE)
    clips = collect(args.folder, args.manifest, exclude=[args.out], include_all=args.include_all)
    if not clips:
        sys.exit("no clips found under %s" % args.folder)

    print("clips     : %d" % len(clips))
    shapes = []
    for path in clips:
        info = probe(path)
        stream = video_of(info)
        if stream is None:
            sys.exit("no video stream in %s" % path)
        duration = float(info.get("format", {}).get("duration") or 0.0)
        shapes.append((stream.get("width"), stream.get("height"), fps_of(stream), duration))
        print("            %6.2fs  %sx%s @%s  %s" % (duration, stream.get("width"), stream.get("height"),
                                                    fps_of(stream), os.path.basename(path)))

    widths = {shape[0] for shape in shapes}
    heights = {shape[1] for shape in shapes}
    rates = {shape[2] for shape in shapes}
    uniform = len(widths) == 1 and len(heights) == 1 and len(rates) == 1
    total = sum(shape[3] for shape in shapes)
    print("total     : %.2fs across %d clips" % (total, len(clips)))

    os.makedirs(os.path.dirname(os.path.abspath(args.out)) or ".", exist_ok=True)
    listing = os.path.join(os.path.dirname(os.path.abspath(args.out)), "concat.txt")
    with open(listing, "w", encoding="utf-8") as handle:
        for path in clips:
            handle.write("file '%s'\n" % os.path.abspath(path).replace("\\", "/").replace("'", "'\\''"))

    filters = []
    target_fps = args.fps or (next(iter(rates)) if uniform else 30.0)
    if args.width or args.height or not uniform or args.force_encode or args.burn_subs:
        width = args.width or next(iter(widths))
        height = args.height or next(iter(heights))
        width -= width % 2
        height -= height % 2
        filters.append("scale=%d:%d:force_original_aspect_ratio=decrease" % (width, height))
        filters.append("pad=%d:%d:(ow-iw)/2:(oh-ih)/2" % (width, height))
        filters.append("fps=%s" % target_fps)
        filters.append("setsar=1")
    if args.burn_subs:
        escaped = args.burn_subs.replace("\\", "/").replace(":", "\\:")
        overrides = []
        if args.sub_font:
            overrides.append("FontName=%s" % args.sub_font)
        if args.sub_margin:
            overrides.append("MarginV=%d" % args.sub_margin)
        style = (":force_style='%s'" % ",".join(overrides)) if overrides else ""
        filters.append("subtitles='%s'%s" % (escaped, style))

    cmd = [FFMPEG, "-y", "-v", "error", "-stats", "-f", "concat", "-safe", "0", "-i", listing]
    if args.audio:
        cmd += ["-i", args.audio]
    if filters:
        cmd += ["-vf", ",".join(filters)]
    encode = bool(filters) or args.force_encode
    if encode:
        cmd += ["-c:v", "libx264", "-preset", "slow", "-crf", str(args.crf), "-pix_fmt", "yuv420p"]
    else:
        cmd += ["-c", "copy"]
    if args.audio:
        cmd += ["-c:a", "aac", "-b:a", "192k", "-shortest"]
    cmd += ["-movflags", "+faststart", args.out]

    proc = run(cmd)
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr.decode("utf-8", "replace")[-4000:])
        sys.exit("ffmpeg join failed")

    info = probe(args.out)
    stream = video_of(info)
    duration = float(info.get("format", {}).get("duration") or 0.0)
    audio = [s for s in info.get("streams", []) if s.get("codec_type") == "audio"]
    size_mb = os.path.getsize(args.out) / 1048576.0
    print("joined    : %s" % ("re-encoded" if encode else "stream copy"))
    print("final     : %s" % args.out)
    print("            %sx%s @%s fps | %.2fs | %.2f MB | audio %s" % (
        stream.get("width"), stream.get("height"), fps_of(stream), duration, size_mb,
        audio[0].get("codec_name") if audio else "none"))
    if duration + 0.25 < total and not args.audio:
        print("note      : final is %.2fs shorter than the clips summed (%.2fs)" % (total - duration, total))
    return 0


if __name__ == "__main__":
    sys.exit(main())
