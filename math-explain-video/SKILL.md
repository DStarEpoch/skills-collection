---
name: math-explain-video
description: Produce a narrated, mathematically honest explainer video for a theorem, proof or worked problem — a Manim-rendered film with one clip per argument step, plan-first structure, a real render/verify loop, and a final cut with optional narration and subtitles. Use this whenever someone asks for a video, animation, or explainer of a math problem, proof, theorem or algorithm; when they want a solution "explained visually" or "turned into a video"; when they hand over a problem set and want teaching material; or when slides/diagrams are not enough and the maths has to unfold in time. Covers proof walkthroughs, derivations, algorithm tracing, and graph/geometry intuition. Also use it when an existing math video needs auditing on accuracy and depth, logical flow, visual relevance, element layout, or visual consistency.
license: MIT
---

# Math explainer video

A math explainer is not a slideshow with a soundtrack. It is an argument that unfolds in time: every line on screen is earned by the line before it, and a viewer who has never seen the problem can follow the whole thing once, without pausing.

The method here is extracted from **TheoremExplainAgent** (TIGER-AI-Lab, ACL 2025, MIT): have a model *plan* the explanation as an ordered list of argument steps, generate one animation per step, render it, and grade the result on **five axes** — accuracy and depth, logical flow, visual relevance, element layout, visual consistency (composite score is their geometric mean). In this skill the model is you: you write the plan, you write the scenes, and the scripts in `scripts/` do the rendering, checking and joining.

Two numbers from that work explain why this skill is shaped the way it is. Rendering is where these pipelines die: with **no retry**, only **3–7 %** of generated scenes render successfully; one repair round lifts it to 33–51 %, and five rounds to **91–96 %**. And generation is not the bottleneck — layout is: automated judges score element layout lowest of all five axes (0.57–0.61 out of 1.0). So this skill spends its effort on a repair loop and on looking at frames, not on writing fancier scenes.

## The one idea that matters

**Three artifacts, three truths.**

| Artifact | It is the truth about | It is verified by |
|---|---|---|
| `plan.json` | what is claimed and in what order | the mathematics itself, checked line by line |
| `scenes/*.py` | what is shown, and when | a draft render plus frames you actually look at |
| `out/final.mp4` | what ships | duration, blank-frame and frame review |

Never let one artifact absorb another. A scene that "works because the animation is pretty" while the narration claims something else has failed. The plan is authoritative: when a scene will not render, fix the scene, not the plan — unless the plan itself is mathematically wrong, in which case fix the plan first and re-derive everything downstream.

**Two failure modes to recognise early:**

- **Talking-head maths.** Narration says "therefore q is even" while the screen shows an unrelated diagram. Fix: one claim per scene, and the claim is on screen in the *same frame* as the words that assert it.
- **Trusting the render.** Manim will happily produce a video with the formula sliding off the bottom edge, or an empty frame because a `VGroup` was built from nothing. Nothing catches that except looking at extracted frames. Always look.

## Size it before you start

Name the scope, then build. A video that "explains a whole chapter" is a different project from one proof.

- **Single topic — a proof, a worked problem, or one algorithm** — 3–20 scenes, 40 s – 6 min. Build it without asking. A genuinely complex topic (a full algorithm with its invariants, a multi-step construction, a long chain of estimates) needs 10–20 scenes, so do not compress it into 7 to fit the budget: the failure mode there is not a bad film but a **truncated** one, with a step quietly dropped. Past ~8 scenes, write the whole plan first, then render and check it in blocks of 3–7 so a broken scene never hides behind a finished one.
- **Multi-topic lesson** — 20+ scenes, 6–15 min. Say so, then build it in parts, checking each part.
- **Course-scale** — stop and propose the single-topic version first: one honest 60-second film beats six unwatched ones.

**On the cap.** The source method (TheoremExplainAgent) hard-caps a plan at 3–7 scenes and 15 minutes. This skill keeps their 15-minute ceiling but raises the per-topic cap to **20**: their 3–7 was tuned on single textbook theorems, and scene count is not what makes a film watchable — the 6–15 s per scene rule and the 40 s – 6 min footage range are.

Keep one scene to one beat, roughly 6–15 s, and let a scene run longer only when the viewer must read something.

## Workflow

Work in this order. The first three steps decide most of the quality.

1. **Solve the problem first, on paper.** Not "sketch the animation" — actually solve it: state the theorem, find the answer, write the full chain of reasoning, and check it independently (substitute a value, try a small case, verify a limit). Write the result into the plan's `answer` and into each scene's `equation`. If you cannot state the answer in one line, you are not ready to animate.
2. **Fix the level and the language.** Who is watching — a first-year student, a contestant, a colleague? That decides whether you show `\gcd(p,q)=1` or explain it in words. Write narration in the language the question was asked in; keep formulas in LaTeX regardless.
3. **Write the plan** (`plan.json`, schema in `assets/plan.example.json`). One entry per argument step, and — following the source method — each entry carries three separate plans, because they fail for different reasons and mixing them produces vague scenes:
   - `vision` — what the viewer sees and how the space is laid out (the storyboard: element list, relative positions, colours, reading order).
   - `technical` — how it is built in Manim (objects, VGroup hierarchy, animations, LaTeX packages needed, estimated duration).
   - `narration` — what is said, in the problem's language, and which cue it syncs to.
   Plus the identifiers the pipeline needs: `id`, `title`, `class`, `file`, `equation`, `duration`, `check`.
   - Narration length sets duration: about 4–5 Chinese characters or 2.5–3 English words per second, plus a beat of silence after each reveal. A 12-second scene is roughly 40–50 Chinese characters.
   - `cues` is the on-screen beat list. Every cue must be a visible event, not a feeling ("公式逐行出现", not "让观众理解").
   - The plan must name the *one new thing* each scene adds. If two scenes add the same thing, merge them.
   - Keep the total honest: `assembly.planned_total_seconds` is compared against the real footage after rendering.
4. **Write the scenes from the skeleton.** Copy `assets/scene_skeleton.py` once per scene. Keep the shared palette, the shared title bar, and the safe animation set; the review criterion "visual consistency" is enforced by using the same helpers in every file, not by remembering to be consistent.
5. **Draft-render at `-ql`.** `python scripts/render.py scenes --plan plan.json --out out/draft --quality l`. This is 480p15 and takes seconds per scene; it exists to catch LaTeX errors, missing names, and shape mismatches cheaply.
6. **Look at the frames.** `python scripts/check_video.py out/draft/scene-03.mp4 --frames 5`. Then open the PNGs with your image-reading tool. Ask, per frame: is anything cut off? Does the highlighted thing match the narration? Is the screen empty or overcrowded? Repeat for every scene — this step is the difference between a render and an explainer.
7. **Fix and re-render, in rounds.** `render.py` prints the last lines of Manim's error for every failed scene and retries by itself. Fix the code, re-render only the broken scenes (`--only scene-03`). Two or three rounds is normal; if a scene still fails after that, simplify the scene (fewer simultaneous objects) rather than fighting the API.
8. **Synthesise the narration, then let it set the timing.** `python scripts/tts_narration.py plan.json --out out/tts --clips out/final-scenes --rate -5% --pad --concat out/tts/narration.mp3`. It prints, per scene, the take's length against the rendered clip. Where the take is **longer** than the clip, the picture is too short: add the difference to that scene's final `self.wait()` and re-render that one scene — never speed the voice up to fit a scene that was planned by character count. Where the take is shorter, `--pad` has already filled the gap with silence so the joined track stays in sync. If the machine has no TTS route the script exits 2; go straight to the subtitle-only path, because a missing voice track must never block the film.
9. **Render the final cut.** `--quality h --fps 30` (1080p30) or `--quality h` alone (1080p60). Then join: `python scripts/assemble.py out/final-scenes --out out/final.mp4 --manifest plan.json --audio out/tts/narration.mp3 --burn-subs out/subtitles.srt --sub-font "<CJK font>"`, dropping `--audio` when there is no narration.
10. **Verify against the five axes.** Run `check_video.py` on the final cut, look at the contact sheet and a handful of frames, then walk the criteria below. Fix what you find; do not ship on "it rendered".

## Code rules that keep generated Manim renderable

Manim punishes a wide API surface. Stay inside this lane.

- **`from manim import *`, one `Scene` subclass per file**, `construct()` builds the whole scene.
- **Animations:** `FadeIn`, `FadeOut`, `Create`, `Write`, `Transform`, `ReplacementTransform`, `Indicate`, `Circumscribe`, `GrowArrow`, `LaggedStart`, `AnimationGroup`. Avoid renamed or deprecated names (`ShowCreation`, `TextMobject`, `TexMobject`, `ShowPassingFlash`), and avoid `Transform` between unrelated mobjects — use `ReplacementTransform` when the shapes differ.
- **Text vs formula:** `Text` for anything with CJK, `MathTex` for formulas, never mixed in one mobject. `MathTex` cannot typeset Chinese; `Text` cannot typeset `\frac` or `\sqrt`.
- **Layout by relation, never by hand coordinates:** `VGroup(...).arrange(DOWN, aligned_edge=LEFT)`, `.next_to(other, DOWN, buff=0.5)`, `.to_edge(UP)`, `.to_corner(UL)`. The source method forbids absolute coordinates outright; hand-typed `move_to([3.7, -2.1, 0])` is how content ends up off-frame at a different resolution.
- **Respect the frame's real numbers.** The 16:9 frame is 14.22 × 8.00 units centred on `(0, 0, 0)`, so keep objects inside roughly x ∈ [−7, 7], y ∈ [−4, 4], leave a **0.5-unit margin** from every edge, and keep at least **0.3 units** between any two objects.
- **Font sizes that survive:** title 28, side labels and formulas 24. More than ~10 words on one line means wrap it into several lines rather than shrinking further.
- **One new object group per `self.play`**, with `run_time` between 0.5 and 2 s, and `self.wait()` after each reveal (0.6–1.5 s). A scene that ends on the last animation reads as truncated.
- **Set quality on the command line**, never in the file: a module-level `config.frame_rate` or `config.pixel_width` is applied after the CLI and silently defeats `-q`.
- **No external assets** (no images, no sound, no data files): the source method bans them, and a scene that depends on a missing file fails on someone else's machine. No promotional content and no quiz interstitials either — they were explicitly excluded.
- **Small helper functions at the top of each file** (`zh(...)`, `mtex(...)`, `title_bar(...)` from the skeleton) so a scene file is 30–80 lines and a fix is local.
- **Reserve the bottom band for burned subtitles.** Burned subtitles occupy roughly the bottom 1.2 units of the frame. Content placed there collides with them — a complexity line at y ≈ -3.1 visibly crossed a two-row subtitle in the first cut of a real video. Keep scene content above y ≈ -3.2, or lift the subtitles with `assemble.py --sub-margin 40`.
- **A formula must be short enough to read.** Split `\frac{a^2+b^2}{c^2+d^2} = \int_0^1 f` into two lines rather than shrinking the font below ~24.

## Verify like a reviewer

Two mechanical gates, then the five axes the source method grades on. The first two are scripted; the rest need your eyes on frames.

1. **It rendered.** `check_video.py` reports duration, resolution, frame rate, structureless ("blank") frames, and black/frozen stretches, and extracts frames. A structureless frame means that scene rendered nothing: fix it before joining. Black stretches and holds are reported as notes, because a dark theme (Manim's default) makes both luminance heuristics unreliable — judge those from the extracted frames.
2. **Durations match the plan.** `render.py` prints actual against planned per scene, and the plan's target total against the footage. A ratio outside 0.8–1.25 means the animation does not match the narration: either the scene is rushed or the narration is short.
3. **Accuracy and depth.** Does the narration explain the theorem *correctly*, and does the video give both the rigorous step and the intuition for why it holds? Re-read every equation once as text (`p^2 = 2q^2`, not "the squared thing"); check signs, indices, quantifiers, and the final answer against your step-1 solution. Score the pair (rigour, intuition) — a video that is only rigorous is a textbook page, only intuitive is a hand-wave.
4. **Logical flow.** Does the contact sheet read as a coherent buildup — title, setup, steps, result, conclusion — with each scene connecting to the previous one? Score 1–5. Look for the two classic breaks: a step that appears before its prerequisite, and a conclusion that was never set up.
5. **Visual relevance.** In each scene's frames, does what is on screen align with the concept being derived at that moment? A decorative diagram that happens to be on screen during a derivation fails this.
6. **Element layout.** Placement and size: is anything cut off at the frame edge, shrunk below reading size, or colliding with another object? Unintentional overlap is the single most common defect in machine-generated Manim, and the one viewers notice first. Check the extracted frames at 1:1 for text collisions and off-frame drift.
7. **Visual consistency.** Same palette, same title bar, same symbol names and colours across scenes; smooth transitions; the accent colour means the same thing every time it appears.

Score each of the five on the source method's anchors and fix anything at 3 or below before shipping:

```
1 Very poor, completely fails the criteria.   4 Good, performs well, no major issues.
2 Below average, significant issues.          5 Excellent, fully meets or exceeds expectations.
3 Acceptable, meets the basics with minor issues.
```

Their automated judges tracked human raters well on visual relevance but poorly on the text-only axes — accuracy and depth, and logical flow (secondary summaries of the paper put the rank correlation near 0.7 for visual relevance and near 0.1–0.2 for the text axes). Do not let a rubric substitute for rereading the mathematics yourself.

## Narration, sound and subtitles

The source method narrates with an in-render TTS service (`manim-voiceover` +
Kokoro) and ships each scene with its own audio and `.srt`. This skill treats
audio as an *optional capability of the machine*: if there is a local TTS route,
`scripts/tts_narration.py` writes one mp3 per scene and `assemble.py --audio`
muxes them; if there is not, the same film ships with burned subtitles only.
Either way the narration text is written first, in the plan.

**Order matters: write the script, synthesise it, then time the scenes to the
audio.** Character-count arithmetic ("≈5 chars per second") is only good enough
to *draft* a plan — the synthesiser is the truth. On a real film measured here,
the takes came out 14 s longer than the footage overall, with individual scenes
1–5 s short; every one of those was a scene planned by character count rather
than by listening.

- Treat the route as optional. `tts_narration.py` exits **2** when nothing
  answers; that is not a failure of the film. Fall back to subtitles and say so.
- `--base` points at the route: `$TTS_BASE_URL`, else the harness's own base URL
  variable (`$DSH_WEB_URL` on the reference implementation), else
  `http://127.0.0.1:19387`. `references/environment.md` documents the five
  endpoints the script expects, so any harness exposing that shape works.
- Fix `--voice` and `--rate` once for the whole film, so it sounds like one
  narrator rather than several. `--rate` is written straight into SSML, so it
  takes percentage strings such as `-5%`.
- `--pad` extends a short take with silence up to the clip's length, which keeps
  one joined track in sync. A **long** take cannot be padded, so that scene
  grows instead (step 8).
- Always build the `.srt` from the plan and burn it even when there is audio:
  `assemble.py --burn-subs subs.srt --sub-font "<CJK font on this machine>"`.
  Subtitles keep the film usable muted.
- Never let a missing audio track block the deliverable, and never ship a
  robot-sounding voice just to have one: subtitles alone beat bad narration.

## Setup

The pipeline needs **Manim Community** (0.22.x) plus **ffmpeg**; LaTeX is needed only when a scene uses formulas. The three scripts need nothing but the standard library and those binaries, so the only thing to manage is the Manim interpreter.

**Use `uv`, and keep the environment inside the video project.** It is already installed on this machine and it keeps Manim out of the system Python and the conda base env; its lockfile is what makes "pin Manim against version drift" real rather than aspirational, with `pyproject.toml` and `uv.lock` sitting next to the scenes they render.

```sh
uv init --python 3.13 math-videos       # Manim 0.22 needs Python >= 3.11
cd math-videos
uv add "manim==0.22.*"                  # add "manim[typst]" for the LaTeX-free math path
uv run manim --version                  # first line must say Manim Community v0.22.x
uv run manim checkhealth                # answer 'n' to the test-render question
```

Run every stage through that environment so `sys.executable` *is* the project Python and Manim resolves with no extra wiring:

```sh
uv run python <skill>/scripts/render.py scenes --plan plan.json --out out/draft --quality l
uv run manim render -ql scenes/scene_01_statement.py Scene01Statement     # one scene, by hand
```

If the scripts do run under some other interpreter, point them at the project instead: `render.py --manim "uv run manim"` (a command string, or a quoted full path). Without `uv`, a plain venv works — never a base environment:

```sh
python -m venv .venv && .venv\Scripts\activate     # Windows; .venv/bin/activate elsewhere
python -m pip install "manim==0.22.*"
```

Non-Python requirements — note that Manim itself no longer needs ffmpeg (since 0.19 it uses PyAV), but the checking and joining scripts do:

```sh
ffmpeg -version                              # check_video.py and assemble.py need ffmpeg + ffprobe
kpsewhich standalone.cls amsmath.sty         # only if you render formulas (MathTex/Tex)
```

Quality presets, since they decide your render times: `-ql` 854×480@15 (draft), `-qm` 1280×720@30, `-qh` 1920×1080@60, `-qp` 2560×1440@60, `-qk` 3840×2160@60. **`-qh` is the default when you pass no `-q` at all**, which is why an unqualified render feels slow. Always call it as `python -m manim` so a `manimgl` install cannot shadow the command.

Notes that save an hour:

- **A zero exit code is not success.** Manim exits 0 for an illegal `-n`/`--resolution`, and a misspelled `construct()` renders a black screen and exits 0. Treat a scene as rendered only when the log says `File ready at '<path>'`, that file is non-empty, and `ffprobe` reads a duration — which is what `render.py` checks.
- **Never call manim without a scene name.** A file with several scenes and no name given makes the CLI wait on stdin, which looks exactly like a hang. `render.py` refuses to render a scene whose class it cannot find, and gives the child `stdin=DEVNULL`.
- **CJK text needs a CJK font through `Text`**, not LaTeX. `Text` uses Pango (bundled with Manim's `ManimPango` — no `pango-view` binary needed). Pick a font that exists on the machine (`Microsoft YaHei` on Windows, `Noto Sans CJK SC` on Linux, `PingFang SC` on macOS); the skeleton's `pick_font()` does this. Routing Chinese through `Tex`/`ctex` has known defects (an `IndexError` with `BraceLabel`, baseline misalignment in mixed text) — avoid it.
- **`MathTex` failures are LaTeX failures.** Read `media/Tex/<hash>.log`: a missing package (`\mathbb`, `\gcd`, `\therefore`) needs `TexTemplate.add_to_preamble`, and `standalone.cls` missing means a minimal TeX install.
- **`-c` is `--config_file`, not a colour**; the background is `config.background_color` or `--background_color`.
- **Windows consoles garble Manim's box-drawing output.** `render.py` sets `PYTHONUTF8=1`/`PYTHONIOENCODING=utf-8` for the child and decodes as UTF-8. Keep that.
- **Never read redirected `ffprobe` output from a file** on Windows: PowerShell's `>` writes UTF-16, so JSON parsing fails on the BOM. Capture the subprocess output instead (which the scripts do) or decode with `utf-8-sig`.

## Scripts

| Script | Use it for |
|---|---|
| `scripts/render.py` | Render every scene to one clip per scene, with per-scene retries, error tails, duration-vs-plan, and a JSON report. `--quality l` draft, `--quality h --fps 30` final, `--only <id>` to iterate on one scene, `--keep-latex` to preserve `media/Tex/*.log` when a formula fails, `--dry-run` to inspect the commands. |
| `scripts/check_video.py` | Inspect any rendered clip or the final cut: real duration, resolution, fps, audio presence, blank/black/frozen detection, frame extraction, contact sheet. Exit code 1 on a real problem, so it can gate a pipeline. |
| `scripts/tts_narration.py` | Synthesise the plan's narration through the local TTS host route: one mp3 per scene, per-scene audio-vs-clip drift, `--pad` (silence up to clip length) and `--concat` (the single track for `--audio`). `--check` tests the route, `--dry-run` lists what would be spoken, `--only` redoes one scene, `--force` re-synthesises; exit code 2 means no route, so ship subtitles only. |
| `scripts/build_srt.py`, `scripts/make_srt.py` | Turn the plan's narration into a `.srt`, timed against the rendered clips. Prefer `make_srt.py`: `build_srt.py` cuts long sentences purely by character count, which splits formulas mid-token (`f(-x) = -` / `f(x)`) and can leave a line starting with a comma; `make_srt.py` keeps the same timing model but never breaks inside a Latin/maths run or before a punctuation mark. |
| `scripts/selftest.py` | End-to-end smoke test on the bundled two-scene example: validate the plan, render at `-ql`, inspect the clips, build subtitles, join the cut, report. Use it to prove a new machine is set up correctly. |
| `scripts/assemble.py` | Join scene clips in plan order (stream copy when they match, one re-encode when they do not), add narration, burn subtitles (CJK needs `--sub-font`, e.g. `Microsoft YaHei`), and report the final duration. |
| `assets/plan.example.json` | The plan schema, filled with a complete worked example (√2 irrational, 5 scenes). |
| `assets/scene_skeleton.py` | The scene template: shared palette, shared title bar, CJK-aware text helpers, the safe animation set, and a graph pattern. |

## Portability, requirements and self-test

Nothing in this skill is tied to one machine: every script imports the standard
library only and shells out to `ffmpeg`/`ffprobe` and Manim. What a machine must
provide:

| Need | Check | Notes |
|---|---|---|
| Python ≥ 3.11 | `python -V` | Manim 0.22 will not install on 3.9/3.10 |
| Manim Community 0.22.x | `python -m manim --version` (through the project venv) | keep it in a project venv with a lockfile, never a base environment |
| ffmpeg + ffprobe | `ffmpeg -version` | `check_video.py` and `assemble.py` need both; a full build also gives `libass` for burned subtitles |
| LaTeX (only for formulas) | `kpsewhich standalone.cls amsmath.sty` | skip it entirely if no scene uses `MathTex` |
| A CJK font (only for CJK text) | the skeleton's `pick_font()` tries `Microsoft YaHei`, `Noto Sans CJK SC`, `PingFang SC`, `Source Han Sans SC` | pass the same name to `assemble.py --sub-font` when burning subtitles |

Run the end-to-end self-test on a throwaway two-scene film — it writes only into
`examples/tiny/out/`:

```sh
python scripts/selftest.py                 # render -> check -> subtitles -> join
python scripts/selftest.py --keep          # keep the artifacts for inspection
python scripts/selftest.py --quality h     # slower, 1080p
```

Cross-platform traps this pipeline has already paid for (keep them in mind when
something behaves oddly on a new machine):

- **`--sub-margin` is not pixels.** It becomes ASS `MarginV`, which libass
  measures against a 384×288 script resolution: `40` puts the top of a one-line
  subtitle at about y = −2.4 in the 8-unit Manim frame. Content that reaches
  below y ≈ −2.4 will collide with burned subtitles.
- **Windows consoles garble Manim output.** `render.py` sets `PYTHONUTF8=1` /
  `PYTHONIOENCODING=utf-8` for the child and decodes as UTF-8; keep that if you
  re-implement any stage.
- **Never read redirected `ffprobe` output from a file** on Windows
  (PowerShell's `>` writes UTF-16 and the BOM breaks JSON parsing). Capture the
  subprocess output, or decode with `utf-8-sig`.
- **`-qh` is the default** when no `-q` is passed, so an unqualified render is
  1080p60 and feels slow; pass `-ql` while iterating.

Narration audio is **optional**. If the machine exposes a local HTTP TTS route,
`scripts/tts_narration.py` drives it (contract in `references/environment.md`);
otherwise the film ships with burned subtitles and no voice track, which is a
complete deliverable.

## References

Read these when the summary above is not enough:

- `references/pipeline.md` — the staged contract in full: plan schema field by field, the render/fix loop with its retry and stop rules, and how the source method (TheoremExplainAgent) splits planning, coding, rendering and evaluation.
- `references/manim-cookbook.md` — the reliable subset of Manim: a minimal runnable scene, the animation and layout vocabulary worth using, `Text`/`MathTex`/CJK rules, graphs and geometry, and the error-to-fix table.
- `references/verify.md` — the review checklist in full, the ffmpeg commands behind `check_video.py`, how to read a contact sheet, timing guidance per language, and the anti-patterns that got explainers rejected.
- `references/environment.md` — what a machine must provide, the portability traps this pipeline has already paid for, and the HTTP contract of the optional narration TTS route (`scripts/tts_narration.py`).

## Anti-patterns

- **Animating before solving.** If the maths is not settled, the animation will encode the mistake, and every later fix costs a re-render.
- **One giant scene.** A single 90-second `construct()` is unmaintainable and unverifiable; split it into argument steps.
- **Silent scenes.** A scene with no narration (or narration with no visual change) is dead time; either say something or cut it.
- **Decorative motion.** Rotating a 3D object while explaining an inequality is noise. Motion must carry a claim.
- **Shipping the draft.** `-ql` is 480p15; never deliver it as the final cut.
- **Trusting the audit script.** `check_video.py` catches blank and over-long clips, not wrong mathematics or text sliding off screen. Those need your eyes on the frames.
