#!/usr/bin/env python3
"""Build subtitles with the skill's timing model but safer line breaking.

The skill's build_srt.py cuts a long sentence purely by character count, which
split formulas mid-token in this film ("如果 f(-x) = -" / "f(x)，…") and once
produced a line starting with a comma. This script keeps build_srt.py's timing
(proportional to chunk length, with a floor, spread over each clip's *measured*
duration) and replaces only the chunking step:

* a Latin/maths run like ``f(-x) = -f(x)`` is one atom and is never split;
* a line never ends just before a punctuation mark (no line starts with "，");
* a line prefers to end right after 、，：； when that is at least half full.

    python make_srt.py plan.json --clips out/final-scenes --out out/subtitles.srt
"""

import argparse
import importlib.util
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def load_build_srt():
    """Reuse the skill's timing/allocation helpers instead of re-deriving them."""
    spec = importlib.util.spec_from_file_location("build_srt", os.path.join(HERE, "build_srt.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


bs = load_build_srt()

ATOM = re.compile(r"[A-Za-z0-9][A-Za-z0-9().,\-+*/\\^\[\]{}²³·=|]*|.", re.S)
BREAK_AFTER = "，、：；"
PUNCT_ONLY = set("，。、：；？！,.;:!?)）")


def atoms_of(text):
    """Latin/maths runs stay whole; a space belongs to the atom before it, so a
    line never opens with a space and CJK/Latin spacing survives."""
    out = []
    for piece in ATOM.findall(text):
        if piece.isspace():
            if out:
                out[-1] += piece
        else:
            out.append(piece)
    return out


def cut_point(atoms, limit):
    """Index (exclusive) to cut `atoms` at, holding the line to <= limit chars."""
    total = 0
    filled = 0
    punctuation_cut = None
    for index, atom in enumerate(atoms):
        if total + len(atom) > limit:
            break
        total += len(atom)
        filled = index + 1
        if atom.endswith(tuple(BREAK_AFTER)):
            punctuation_cut = index + 1
    else:
        return len(atoms)  # everything fits
    cut = filled if filled else 1
    # a line must not start with punctuation: pull those marks back
    while cut < len(atoms) and atoms[cut] in PUNCT_ONLY:
        cut += 1
    if punctuation_cut is not None and punctuation_cut >= max(1, cut // 2):
        candidate = punctuation_cut
        while candidate < len(atoms) and atoms[candidate] in PUNCT_ONLY:
            candidate += 1
        return candidate
    return cut


def chunk(text, limit):
    lines = []
    for sentence in bs.split_sentences(text):
        atoms = atoms_of(sentence)
        while atoms:
            cut = cut_point(atoms, limit)
            lines.append("".join(atoms[:cut]).strip())
            atoms = atoms[cut:]
    return [line for line in lines if line]


def main():
    parser = argparse.ArgumentParser(description="Build subtitles with token-safe line breaking.")
    parser.add_argument("plan")
    parser.add_argument("--clips", default="", help="folder of rendered clips, for real durations")
    parser.add_argument("--out", required=True)
    parser.add_argument("--max-chars", type=int, default=24)
    parser.add_argument("--floor", type=float, default=1.1)
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
            continue
        duration = float(scene.get("duration") or 0.0)
        if args.clips:
            path = os.path.join(args.clips, scene_id + ".mp4")
            if os.path.exists(path):
                measured = bs.clip_duration(path)
                if measured:
                    duration = measured
        if duration <= 0:
            continue
        narration = scene.get("narration", {}).get("script", "").strip()
        if not narration:
            clock += duration
            continue
        lines = chunk(narration, args.max_chars)
        shares = bs.allocate([len(line) for line in lines], duration, args.floor)
        cursor = clock
        scene_end = clock + duration
        for line, share in zip(lines, shares):
            start = min(cursor, scene_end - 0.2)
            end = min(cursor + max(share, 0.3), scene_end)
            entries.append((start, max(end, start + 0.2), line))
            cursor += share
        clock = scene_end

    os.makedirs(os.path.dirname(os.path.abspath(args.out)) or ".", exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as handle:
        for index, (start, end, text) in enumerate(entries, start=1):
            handle.write("%d\n%s --> %s\n%s\n\n" % (index, bs.stamp(start), bs.stamp(end), text))

    print("wrote     : %s" % args.out)
    print("subtitles : %d lines over %.1fs" % (len(entries), clock))
    print("longest   : %d chars (limit %d)" % (max((len(t) for _, _, t in entries), default=0), args.max_chars))
    for _, _, text in entries:
        print("   %s" % text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
