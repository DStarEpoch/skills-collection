# Changelog

## 1.0.0 — first packaged release

Turned a working private skill into a harness-neutral package: stripped the
machine-specific environment notes, added a runnable example and an end-to-end
self-test, and documented the optional narration route instead of depending on
one implementation of it.

**Pipeline** (`SKILL.md`)

- plan-first: one scene per argument step, each carrying separate `vision` /
  `technical` / `narration` plans, because they fail for different reasons
- scene budget raised from the source method's 3–7 to **3–20 per topic**: their
  cap was tuned on single textbook theorems and silently truncates anything with
  more working parts (recorded as a deliberate deviation, 15-minute ceiling kept)
- five-axis verification, with the honest note that automated judges track humans
  poorly on the two text-only axes

**Scripts**

- `render.py` — one clip per scene, per-scene retries, error tails, duration vs
  plan, JSON report
- `check_video.py` — duration/resolution/fps/audio, blank-black-frozen detection,
  frame extraction, contact sheet
- `assemble.py` — join in plan order, mux narration, burn subtitles
- `make_srt.py` — subtitles timed to the real clips; unlike `build_srt.py` it
  never breaks inside a Latin/maths run or leaves a line starting with punctuation
- `tts_narration.py` — optional narration audio from a local HTTP TTS route: one
  mp3 per scene, per-scene audio-vs-clip drift, `--pad` to clip length, `--concat`
  for a single track; exits **2** when no route answers
- `selftest.py` — renders, inspects, subtitles and joins `examples/tiny/`, so a
  new machine can be validated with one command

**Measured facts recorded** (from building two real films)

- Chinese narration via Edge TTS at `rate: -5%` runs at **≈5.1 chars/s**, so the
  "4–5 chars/s" drafting rule is honest; the failure mode is a scene planned too
  tight, not a slow voice (one film's takes were 14 s longer than its footage)
- `--sub-margin` is ASS script units (384×288), not pixels — `40` puts a one-line
  subtitle's top near y = −2.4 in the Manim frame
- `check_video.py --sheet` time captions can be wrong while single-frame
  extraction is accurate; prefer `ffmpeg -ss`
- the `--rate -5%` form trips argparse (it looks like an option); the script
  rewrites it, and `--rate=-5%` always works
