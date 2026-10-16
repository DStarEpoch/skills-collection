#!/usr/bin/env python3
"""Turn a plan's narration into subtitles, timed against the rendered clips.

    python build_srt.py plan.json --clips out/final-scene --out out/subtitles.srt

Why this exists: the source method narrates with in-render TTS, so its subtitles
come out of the same pass as the audio. This pipeline has no speech, so the
narration script *is* the subtitle track — and it has to be broken into readable
chunks and spread across each scene's real duration (read from the rendered clip,
because that, not the plan, is what the viewer sees).

Chunking: split on sentence-ending punctuation, then break anything longer than
--max-chars at a comma. Timing: proportional to chunk length, with a floor so a
short line never flashes, and the excess taken back from the longer chunks.
"""

import argparse
import json
import os
import re
import subprocess
import sys

FFPROBE = os.environ.get("FFPROBE", "ffprobe")
SENTENCE_END = "。！？；!?;"
COMMA = "，,、：:"


def clip_duration(path):
    proc = subprocess.run(
        [FFPROBE, "-v", "error", "-show_entries", "format=duration",
         "-of", "default=noprint_wrappers=1:nokey=1", path],
        capture_output=True)
    try:
        return float(proc.stdout.decode("utf-8", "replace").strip())
    except ValueError:
        return None


def split_sentences(text):
    """Sentences, each keeping its own closing punctuation."""
    out = []
    current = ""
    for char in text:
        current += char
        if char in SENTENCE_END:
            out.append(current.strip())
            current = ""
    if current.strip():
        out.append(current.strip())
    return out


def split_long(sentence, max_chars):
    """Break an over-long sentence at commas, greedily, keeping under max_chars."""
    if len(sentence) <= max_chars:
        return [sentence]
    pieces = []
    current = ""
    for char in sentence:
        current += char
        if char in COMMA and len(current) >= max_chars * 0.6:
            pieces.append(current.strip())
            current = ""
        elif len(current) >= max_chars:
            pieces.append(current.strip())
            current = ""
    if current.strip():
        pieces.append(current.strip())
    # a lone trailing comma piece reads badly; glue it back on
    if len(pieces) > 1 and len(pieces[-1]) <= 3:
        pieces[-2] += pieces[-1]
        pieces.pop()
    return pieces


def allocate(weights, total, floor):
    """Split `total` seconds across weights, keeping each share >= floor."""
    count = len(weights)
    if count == 0:
        return []
    if total < floor * count:  # not enough time: give everyone an equal share
        return [total / count] * count
    shares = [total * w / sum(weights) for w in weights]
    for _ in range(20):
        short = [i for i, s in enumerate(shares) if s < floor - 1e-9]
        if not short:
            break
        spare = sum(floor - shares[i] for i in short)
        for i in short:
            shares[i] = floor
        donors = [i for i, s in enumerate(shares) if s > floor + 1e-9]
        if not donors:
            break
        pool = sum(shares[i] for i in donors) - spare
        if pool <= 0:
            break
        for i in donors:
            shares[i] = pool * shares[i] / sum(shares[j] for j in donors)
    return shares


def stamp(seconds):
    seconds = max(0.0, seconds)
    hours, rest = divmod(seconds, 3600)
    minutes, secs = divmod(rest, 60)
    whole = int(secs)
    millis = int(round((secs - whole) * 1000))
    if millis == 1000:
        whole, millis = whole + 1, 0
    return "%02d:%02d:%02d,%03d" % (int(hours), int(minutes), whole, millis)


def main():
    parser = argparse.ArgumentParser(description="Build subtitles from a plan's narration.")
    parser.add_argument("plan")
    parser.add_argument("--clips", default="", help="folder of rendered clips, for real durations")
    parser.add_argument("--out", required=True, help="subtitle file to write")
    parser.add_argument("--max-chars", type=int, default=26, help="longest subtitle line (default 26)")
    parser.add_argument("--floor", type=float, default=1.1, help="shortest time a line stays up (default 1.1 s)")
    parser.add_argument("--gap", type=float, default=0.0, help="blank gap between lines (default 0)")
    args = parser.parse_args()

    with open(args.plan, encoding="utf-8") as handle:
        plan = json.load(handle)
    scenes = {scene["id"]: scene for scene in plan.get("scenes", [])}
    order = plan.get("assembly", {}).get("order") or [s["id"] for s in plan.get("scenes", [])]

    entries = []
    clock = 0.0
    for scene_id in order:
        scene = scenes.get(scene_id)
        if not scene:
            print("note      : %s is in the cut order but has no scene entry" % scene_id)
            continue
        planned = float(scene.get("duration") or 0.0)
        duration = planned
        if args.clips:
            path = os.path.join(args.clips, scene_id + ".mp4")
            if os.path.exists(path):
                measured = clip_duration(path)
                if measured:
                    duration = measured
            else:
                print("note      : no clip for %s, using the planned %.1fs" % (scene_id, planned))
        if duration <= 0:
            continue
        narration = scene.get("narration", {}).get("script", "").strip()
        if not narration:
            clock += duration
            continue
        chunks = []
        for sentence in split_sentences(narration):
            chunks.extend(split_long(sentence, args.max_chars))
        shares = allocate([len(c) for c in chunks], duration, args.floor)
        cursor = clock
        for chunk, share in zip(chunks, shares):
            start = cursor
            end = cursor + share - args.gap
            if end <= start:
                end = start + 0.2
            entries.append((start, end, chunk))
            cursor += share
        clock += duration

    os.makedirs(os.path.dirname(os.path.abspath(args.out)) or ".", exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as handle:
        for index, (start, end, text) in enumerate(entries, start=1):
            handle.write("%d\n%s --> %s\n%s\n\n" % (index, stamp(start), stamp(end), text))

    print("wrote     : %s" % args.out)
    print("subtitles : %d lines over %.1fs" % (len(entries), clock))
    longest = max((len(t) for _, _, t in entries), default=0)
    print("longest   : %d chars (limit %d)" % (longest, args.max_chars))
    return 0


if __name__ == "__main__":
    sys.exit(main())
