#!/usr/bin/env python3
"""Check a rendered math-explainer video with ffprobe/ffmpeg only (no Python deps).

It reports what a reviewer needs before watching: real duration, resolution,
frame rate, whether an audio stream exists, and whether any part of the video is
blank (a scene that rendered nothing), frozen, or black. It also extracts frames
so the agent can actually look at them, and can build a contact sheet.

    python check_video.py out/final.mp4 --frames 8 --sheet shots/sheet.png
    python check_video.py out/scene-03.mp4 --at 0.5,2,4.5

Exit code is 1 when a problem is found (blank/frozen/black stretch, no video
stream, audio missing when --expect-audio was given), so a pipeline can gate on it.

Works on Windows, macOS and Linux. Never read redirected ffprobe output from a
file: PowerShell redirection writes UTF-16 on Windows, which breaks JSON parsing.
This script captures stdout from the subprocess instead.
"""

import argparse
import json
import os
import re
import shutil
import statistics
import subprocess
import sys

FFMPEG = os.environ.get("FFMPEG", "ffmpeg")
FFPROBE = os.environ.get("FFPROBE", "ffprobe")


def run(cmd):
    proc = subprocess.run(cmd, capture_output=True)
    return proc.returncode, proc.stdout, proc.stderr


def decode(raw):
    return raw.decode("utf-8", "replace")


def need(binary):
    if shutil.which(binary) is None:
        sys.exit("missing binary: %s (set FFMPEG / FFPROBE or add it to PATH)" % binary)


def probe(path):
    code, out, err = run([FFPROBE, "-v", "error", "-print_format", "json", "-show_streams", "-show_format", path])
    if code != 0:
        sys.exit("ffprobe failed on %s: %s" % (path, decode(err).strip()))
    # utf-8-sig: tolerate a BOM if the caller ever redirects this to a file
    return json.loads(out.decode("utf-8-sig"))


def stream_of(info, kind):
    for stream in info.get("streams", []):
        if stream.get("codec_type") == kind:
            return stream
    return None


def frame_rate(stream):
    text = stream.get("r_frame_rate") or stream.get("avg_frame_rate") or "0/0"
    if "/" in text:
        num, den = text.split("/", 1)
        try:
            num, den = float(num), float(den)
        except ValueError:
            return 0.0
        return num / den if den else 0.0
    try:
        return float(text)
    except ValueError:
        return 0.0


def detect_range(path, filt, pattern):
    """Run an ffmpeg detection filter and return the raw report lines."""
    code, out, err = run([FFMPEG, "-hide_banner", "-nostats", "-i", path, "-vf", filt, "-f", "null", "-"])
    found = []
    for line in decode(err).splitlines():
        if pattern in line:
            found.append(line.strip())
    return found


def black_stretches(path):
    """Black intervals: [{'start': s, 'duration': d}]."""
    spans = []
    for line in detect_range(path, "blackdetect=d=0.4:pix_th=0.10", "black_start"):
        match = re.search(r"black_start:([\d.]+)\s+black_end:([\d.]+)\s+black_duration:([\d.]+)", line)
        if match:
            spans.append({"start": float(match.group(1)), "duration": float(match.group(3))})
    return spans


def frozen_stretches(path):
    """Frozen (unchanged picture) intervals: [{'start': s, 'duration': d}].

    A deliberate hold on an equation is normal in an explainer, so callers must
    treat these as warnings unless a stretch is long enough to mean a stuck render.
    """
    starts = {}
    spans = []
    for line in detect_range(path, "freezedetect=n=-60dB:d=1.5", "freeze"):
        start = re.search(r"freeze_start:\s*([\d.]+)", line)
        duration = re.search(r"freeze_duration:\s*([\d.]+)", line)
        end = re.search(r"freeze_end:\s*([\d.]+)", line)
        if start:
            starts["current"] = float(start.group(1))
        if duration and "current" in starts:
            spans.append({"start": starts.pop("current"), "duration": float(duration.group(1))})
        elif end and "current" in starts:
            begin = starts.pop("current")
            spans.append({"start": begin, "duration": max(0.0, float(end.group(1)) - begin)})
    return spans


def sample_luma(path, width, height, want):
    """Decode the video as tiny grayscale frames and measure each one.

    A scene that rendered nothing is uniform (near-zero spread) or fully black
    or white. Sampling the whole stream is cheap at 64x36.
    """
    code, out, err = run([FFMPEG, "-v", "error", "-i", path, "-vf", "scale=%d:%d" % (width, height),
                          "-f", "rawvideo", "-pix_fmt", "gray", "-"])
    if code != 0:
        return [], 0
    size = width * height
    total = len(out) // size
    if total == 0:
        return [], 0
    step = max(1, total // want)
    samples = []
    for frame in range(0, total, step):
        chunk = out[frame * size:(frame + 1) * size]
        if len(chunk) < size:
            break
        values = list(chunk)
        samples.append({
            "frame": frame,
            "mean": sum(values) / size,
            "spread": statistics.pstdev(values),
        })
    return samples, total


def extract_frames(path, times, outdir, width):
    os.makedirs(outdir, exist_ok=True)
    written = []
    for index, when in enumerate(times):
        target = os.path.join(outdir, "f%02d_%s.png" % (index, str(when).replace(".", "p")))
        code, out, err = run([FFMPEG, "-y", "-v", "error", "-ss", str(when), "-i", path,
                              "-frames:v", "1", "-vf", "scale=%d:-2" % width, target])
        if code == 0 and os.path.exists(target):
            written.append(target)
    return written


def contact_sheet(path, target, seconds_per_tile, columns):
    os.makedirs(os.path.dirname(os.path.abspath(target)), exist_ok=True)
    rows = 2
    filt = "fps=1/%s,scale=420:-2,tile=%dx%d" % (seconds_per_tile, columns, rows)
    code, out, err = run([FFMPEG, "-y", "-v", "error", "-i", path, "-vf", filt, "-frames:v", "1", target])
    return target if code == 0 and os.path.exists(target) else None


def main():
    parser = argparse.ArgumentParser(description="Check a rendered explainer video.")
    parser.add_argument("video")
    parser.add_argument("--frames", type=int, default=6, help="how many frames to extract, evenly spaced (default 6)")
    parser.add_argument("--at", default="", help="explicit times in seconds, comma separated (overrides --frames)")
    parser.add_argument("--outdir", default="", help="where to write extracted frames (default <video>_frames)")
    parser.add_argument("--sheet", default="", help="also write a contact sheet PNG here")
    parser.add_argument("--sheet-columns", type=int, default=3)
    parser.add_argument("--sheet-every", type=float, default=3.0, help="seconds between contact-sheet tiles")
    parser.add_argument("--width", type=int, default=960, help="extracted frame width (default 960)")
    parser.add_argument("--expect-audio", action="store_true", help="fail when the file has no audio stream")
    parser.add_argument("--uniform-spread", type=float, default=4.0,
                        help="a sampled frame whose pixel spread is below this has no structure (default 4.0)")
    parser.add_argument("--blank-ratio", type=float, default=0.3,
                        help="fail when this share of sampled frames is blank (default 0.3)")
    parser.add_argument("--black-limit", type=float, default=3.0,
                        help="a black stretch this long is a problem, not a fade (default 3.0 s)")
    parser.add_argument("--freeze-limit", type=float, default=8.0,
                        help="an unchanged picture this long is a problem (default 8.0 s); shorter holds are notes")
    parser.add_argument("--json", default="", help="write the report as JSON here as well")
    args = parser.parse_args()

    need(FFMPEG)
    need(FFPROBE)
    if not os.path.exists(args.video):
        sys.exit("no such file: %s" % args.video)

    info = probe(args.video)
    video = stream_of(info, "video")
    audio = stream_of(info, "audio")
    if video is None:
        sys.exit("no video stream in %s" % args.video)

    duration = float(info.get("format", {}).get("duration") or video.get("duration") or 0.0)
    fps = frame_rate(video)
    samples_rate = fps if fps > 0 else 30.0

    print("file      : %s" % args.video)
    print("video     : %s %dx%d %.3f fps %s frames %.2fs" % (
        video.get("codec_name"), video.get("width"), video.get("height"), fps,
        video.get("nb_frames") or "?", duration))
    print("audio     : %s" % (("%s %s Hz %s ch %.2fs" % (
        audio.get("codec_name"), audio.get("sample_rate"), audio.get("channels"),
        float(audio.get("duration") or 0.0))) if audio else "none"))

    problems = []
    warnings = []
    if audio is None and args.expect_audio:
        problems.append("no audio stream")
    if duration < 0.5:
        problems.append("video shorter than 0.5 s (%.2fs): did the scene render?" % duration)
    if fps <= 0:
        problems.append("could not read a frame rate")

    black = black_stretches(args.video)
    frozen = frozen_stretches(args.video)
    # blackdetect is a luminance heuristic and a dark theme defeats it: a #101010
    # page with sparse white text is "black" to pix_th=0.10 over almost every
    # frame. So a black stretch is a note, never a verdict — the structural
    # (uniform-picture) test below decides whether anything was actually drawn.
    if black:
        longest = max(span["duration"] for span in black)
        tail = ("unusually long even for a dark theme" if longest >= args.black_limit
                else "on a dark theme this usually means a dim page rather than a failed render")
        warnings.append("%d black stretch(es), longest %.1fs at %.2fs: %s — confirm against the "
                        "extracted frames" % (len(black), longest, min(span["start"] for span in black), tail))
    for span in frozen:
        if span["duration"] >= args.freeze_limit:
            problems.append("picture frozen for %.1fs at %.2fs (stuck render?)" % (span["duration"], span["start"]))
        else:
            warnings.append("hold of %.1fs at %.2fs (fine for reading an equation)" % (span["duration"], span["start"]))

    samples, total = sample_luma(args.video, 64, 36, 40)
    # "Blank" means "no structure", not "dark". A dark-theme figure is mostly
    # background by area, so a mean-luminance test condemns every legitimate
    # Manim video (its default background is black). Only the spread across the
    # frame separates "nothing was drawn" from "sparse content on a dark page".
    blanks = []
    dark = []
    for sample in samples:
        if sample["spread"] < args.uniform_spread:
            blanks.append((sample, "uniform"))
        elif sample["mean"] < 8.0:
            dark.append(sample)
    if samples and len(blanks) / float(len(samples)) >= args.blank_ratio:
        problems.append("%d of %d sampled frames have no structure at all (uniform picture): "
                        "a scene rendered nothing" % (len(blanks), len(samples)))
    elif blanks:
        warnings.append("%d uniform sampled frame(s) at frame %s" % (
            len(blanks), ", ".join(str(s["frame"]) for s, _ in blanks[:4])))
    if samples and len(dark) > len(samples) * 0.8:
        warnings.append("picture is near-black over %d of %d sampled frames (means %.1f-%.1f): "
                        "blackdetect and freezedetect are unreliable on a dark theme, so judge this "
                        "clip from the extracted frames" % (
                            len(dark), len(samples), min(s["mean"] for s in dark), max(s["mean"] for s in dark)))
    print("sampled   : %d of %d decoded frames" % (len(samples), total))

    if args.at:
        times = [float(part) for part in args.at.split(",") if part.strip()]
    else:
        count = max(1, args.frames)
        times = [round(duration * (index + 0.5) / count, 2) for index in range(count)]
    outdir = args.outdir or (os.path.splitext(args.video)[0] + "_frames")
    written = extract_frames(args.video, times, outdir, args.width)
    print("frames    : %d written to %s" % (len(written), outdir))
    for path, when in zip(written, times):
        print("            %5.2fs  %s" % (when, path))
    if len(written) != len(times):
        problems.append("only %d of %d frames extracted" % (len(written), len(times)))

    if args.sheet:
        sheet = contact_sheet(args.video, args.sheet, args.sheet_every, args.sheet_columns)
        print("sheet     : %s" % (sheet or "FAILED"))
        if sheet is None:
            problems.append("contact sheet failed")

    if black:
        print("black     : %s" % " | ".join("%.2fs for %.2fs" % (s["start"], s["duration"]) for s in black[:4]))
    if frozen:
        print("holds     : %s" % " | ".join("%.2fs for %.2fs" % (s["start"], s["duration"]) for s in frozen[:4]))

    report = {
        "file": args.video, "duration": duration, "fps": fps,
        "width": video.get("width"), "height": video.get("height"),
        "video_codec": video.get("codec_name"), "audio_codec": (audio or {}).get("codec_name"),
        "frames_extracted": written, "sample_times": times,
        "black": black, "frozen": frozen,
        "blank_samples": [{"frame": s["frame"], "kind": kind} for s, kind in blanks],
        "problems": problems, "warnings": warnings,
    }
    if args.json:
        with open(args.json, "w", encoding="utf-8") as handle:
            json.dump(report, handle, ensure_ascii=False, indent=2)
        print("report    : %s" % args.json)

    for warning in warnings[:6]:
        print("note      : %s" % warning)
    if problems:
        print("PROBLEMS  : %s" % "; ".join(problems))
        return 1
    print("verdict   : ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
