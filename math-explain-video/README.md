# math-explain-video

Turn a theorem, a proof, or a worked problem into an **explainer film**: a plan
of argument steps, one Manim clip per step, a real render-and-verify loop, and a
final cut with burned subtitles — plus an optional voice track.

The method comes from **TheoremExplainAgent** (TIGER-AI-Lab, ACL 2025, MIT):
plan the explanation as an ordered list of argument steps, generate one animation
per step, render it, and grade the result on five axes (accuracy and depth,
logical flow, visual relevance, element layout, visual consistency). This package
is a harness-neutral implementation of that pipeline: the agent writes the plan
and the scenes, and `scripts/` does the rendering, checking and joining.

Two numbers from that work shape everything here: with no repair round only
3–7 % of generated scenes render successfully (one round lifts it to 33–51 %,
five to 91–96 %), and layout is the weakest axis in automated judging. So this
package spends its effort on the retry loop and on *looking at extracted frames*,
not on writing fancier scenes.

## What's in the box

```
SKILL.md                    the instructions an agent follows (entry point)
README.md                   this file
references/pipeline.md      the staged contract in full: plan schema, render/fix loop
references/manim-cookbook.md the reliable subset of Manim + an error→fix table
references/verify.md        the review checklist and the ffmpeg commands behind it
references/environment.md   requirements, portability traps, optional TTS route
scripts/render.py           one clip per scene, per-scene retries, duration-vs-plan
scripts/check_video.py      duration/resolution/fps/blank/frozen + frame extraction
scripts/assemble.py         join clips, mux narration, burn subtitles
scripts/make_srt.py         subtitles timed to the real clips (token-safe line breaks)
scripts/build_srt.py        the original subtitle builder (kept; cruder line breaks)
scripts/tts_narration.py    optional: one mp3 per scene from a local TTS route
scripts/selftest.py         end-to-end smoke test on examples/tiny
assets/plan.example.json    the plan schema, filled with a 5-scene worked example
assets/scene_skeleton.py    copy this once per scene
examples/tiny/              a runnable 2-scene toy film used by the self-test
```

`assets/plan.example.json` documents the schema (it has no scene files, so it is
not runnable); `examples/tiny/` is runnable and is what the self-test drives.

## Install

A skill is just a directory with `SKILL.md` at its root. Copy this whole
directory where your harness looks for skills:

| Harness | Typical location |
|---|---|
| Claude Code | `~/.claude/skills/math-explain-video/` (or `<project>/.claude/skills/…`) |
| Codex / AGENTS.md-style agents | `~/.codex/skills/math-explain-video/`, or point your `AGENTS.md` at `SKILL.md` |
| Cursor | `<project>/.cursor/skills/math-explain-video/`, or a rule that references `SKILL.md` |
| DSH | `~/.dsh/skills/math-explain-video/` |
| anything else | hand the agent the path to `SKILL.md` and let it read the file |

Nothing here is harness-specific: the scripts import the standard library only
and shell out to `manim` and `ffmpeg`/`ffprobe`.

## Requirements

| Need | Check |
|---|---|
| Python ≥ 3.11 | `python -V` |
| Manim Community 0.22.x | `python -m manim --version` (inside the project venv) |
| ffmpeg + ffprobe | `ffmpeg -version` |
| LaTeX — only if a scene uses formulas | `kpsewhich standalone.cls amsmath.sty` |
| a CJK font — only for CJK text | `Microsoft YaHei` / `Noto Sans CJK SC` / `PingFang SC` |

Keep Manim in a project venv with a lockfile, never in a base environment:

```sh
uv init --python 3.13 my-film && cd my-film
uv add "manim==0.22.*"
```

## Verify the install

```sh
python scripts/selftest.py --keep
```

It validates a plan, renders the two-scene example at 480p15, inspects the clips,
builds subtitles, joins the cut, and inspects that — printing `selftest : PASS`
with the final duration when the machine is ready. Add `--sub-font "Microsoft
YaHei"` to exercise CJK subtitle burning, `--quality h` for 1080p.

## Quickstart on your own problem

```sh
# 1. write plan.json (schema: assets/plan.example.json) and one scene file per step
cp <skill>/assets/scene_skeleton.py scenes/scene_01_statement.py

# 2. draft-render at 480p15 — seconds per scene, catches LaTeX and name errors
uv run python <skill>/scripts/render.py scenes --plan plan.json --out out/draft --quality l

# 3. LOOK at the frames; this is the step that separates a render from an explainer
uv run python <skill>/scripts/check_video.py out/draft/scene-01.mp4 --frames 5

# 4. final cut, subtitles, join
uv run python <skill>/scripts/render.py scenes --plan plan.json --out out/clips --quality h --fps 30
uv run python <skill>/scripts/make_srt.py plan.json --clips out/clips --out out/subtitles.srt
uv run python <skill>/scripts/assemble.py out/clips --manifest plan.json --out out/film.mp4 \
    --burn-subs out/subtitles.srt --sub-font "Microsoft YaHei"
```

## Optional: narration audio

If the machine exposes a local HTTP TTS route, `scripts/tts_narration.py` writes
one mp3 per scene and reports each take's length against its rendered clip:

```sh
python scripts/tts_narration.py plan.json --out out/tts --clips out/clips \
    --voice <voice> --rate=-5% --pad --concat out/tts/narration.mp3
python scripts/assemble.py out/clips --manifest plan.json --out out/film.mp4 \
    --audio out/tts/narration.mp3 --burn-subs out/subtitles.srt --sub-font "Microsoft YaHei"
```

The five endpoints it expects are documented in `references/environment.md`. It
**exits 2** when no route answers — that is not a failure of the film: build the
`.srt` and ship subtitles only. Never let a missing voice track block a cut.

The important ordering rule: **write the script, synthesise it, then time the
scenes to the audio.** Character-count arithmetic is good enough to draft a plan
and nothing more — on a real film the takes came out 14 s longer than the
footage, scene by scene 1–5 s short, and every one of those was a scene planned
by counting characters.

## Provenance and licence

MIT — see `LICENSE`. The plan schema, the five review axes and the staged
pipeline are adapted from **TheoremExplainAgent** (TIGER-AI-Lab, ACL 2025, MIT);
the scripts, the portability work and the recorded measurements are original to
this package. If you publish something built with it, cite the paper:

> TheoremExplainAgent: Towards Multimodal Explanations for LLM Theorem
> Understanding (TIGER-AI-Lab, ACL 2025).

## Honest limitations

- **No TTS is bundled.** Narration audio depends on a route the machine must
  provide; without it the film is silent with subtitles, which is a complete
  deliverable.
- **The five-axis score is a rubric, not a proof.** Automated judges tracked
  humans poorly on the text-only axes (accuracy, logical flow), so re-read the
  mathematics yourself.
- **`check_video.py --sheet` labels can be wrong** (measured): the single-frame
  extractions are accurate, the contact sheet's time captions are not. Prefer
  `ffmpeg -ss <t> -i clip.mp4 -frames:v 1 out.png` when it matters.
- **`--sub-margin` is in ASS script units, not pixels** (libass measures against a
  384×288 script resolution). See `references/environment.md`.
