# The pipeline

How a problem becomes a film, stage by stage, and why each stage exists. This is
the extracted contract; the numbers and rules in it come from
**TheoremExplainAgent** (TIGER-AI-Lab, ACL 2025, arXiv 2502.19400, MIT licensed),
with the adaptations this environment needs noted at the end.

## Why staged at all

Their ablation is the argument: **with no repair round, only 3–7 % of generated
scenes render successfully.** One repair round reaches 33–51 %, five rounds
91–96 %. So the pipeline is not "write good code"; it is "write code, render it,
read the error, repair it" — and each stage must be cheap enough to repeat. That
is also why the plan, the code and the render are three separate artifacts: when
something is wrong you need to know *which* one to fix.

Their judge models put the five axes in a stable order of weakness: **element
layout is the worst (0.57–0.61 of 1.0), logical flow the best.** Layout is where
a generated explainer loses marks, which is why this skill spends most of its
verification effort on extracted frames rather than on the code.

## Stage 1 — scene outline

One beat per scene, **3 to 20 scenes** for a single topic (the source method caps
at 3–7; this skill raises it to 20 so a complex topic is not truncated), total under
15 minutes, with 40 s – 6 min of footage as the honest sweet spot. Each scene needs:

- **title** (2–5 words),
- **purpose** — the learning objective, and how it connects to the previous scene,
- **description** — what happens,
- **layout** — the spatial concept, respecting the margins.

Two ordering rules matter: scenes must **build progressively** (start with the
simplest layout, increase complexity later), and the objectives must be
distributed evenly rather than front-loaded. If two scenes carry the same
objective, merge them.

## Stage 2 — the three-part scene plan

The source method plans each scene with three *separate* model calls, and the
separation is the point: each part fails differently.

| Part | Answers | Must contain |
|---|---|---|
| **vision storyboard** | what the viewer sees | element list, spatial layout by relative position, colour/style, reading order, sub-scene breakdown with the Wait buffers between beats |
| **technical implementation** | how it is built | Manim objects, VGroup hierarchy, positioning strategy, animation methods and lifecycles (`FadeIn`/`FadeOut` pairs), LaTeX packages needed, font sizes, estimated duration |
| **animation + narration** | what is said and when | `run_time` per animation, `Wait()` durations *with their pedagogical purpose*, and the narration script |

Three rules from their prompts, carried over verbatim in spirit:

- **No absolute coordinates.** Positioning is `next_to`, `align_to`, `shift`,
  `to_corner`, `move_to(ORIGIN)` — from the origin, the margins, or another
  object. Absolute coordinates are how content drifts off-frame.
- **Spatial constraints are mandatory, not advisory:** safe-area margin 0.5 units
  on all sides, minimum 0.3 units between any two objects, measured edge to edge.
- **No external assets** — Manim built-ins and procedural generation only.
  (They also forbid promotional content and quiz interstitials; keep those out.)

For the narration, their instruction is worth copying outright: the script should
**teach step by step, not describe what is happening**. It should explain
concepts in order, use analogies and real examples, pose questions, summarise key
points, connect smoothly with the previous and next scenes, and avoid repetitive
introductions and conclusions.

## Stage 3 — Manim code

One scene class per file, named after the scene, no `if __name__ == "__main__"`,
no external assets, imports explicit. Their generation prompt adds constraints
worth keeping: no custom background rectangles (the default background is fine),
never black text, a named colour palette reused everywhere, complete code with
its helper functions rather than placeholders, and animation timings that match
the narration plan.

Two habits that came out of their failure modes:

- **Declare LaTeX packages explicitly.** Anything beyond Manim's default template
  needs a `TexTemplate` with `add_to_preamble(r"\usepackage{...}")`, or the render
  dies on a missing `\mathbb` / `\gcd` / `\therefore`.
- **Keep the scene self-contained.** The narration treats all scenes as one
  continuous film, but each scene must render on its own: never rely on an object
  or a variable defined in another scene file.

## Stage 4 — render and repair

The loop, per scene, independent of the others:

1. render the scene;
2. on success, record the clip and its duration;
3. on failure, capture the error, **fix the code**, and render again;
4. budget: the first version plus **up to five repairs** (their default
   `max_retries`), then stop and report.

Rules that keep this loop honest:

- **Fix the code, not the plan** — unless the plan is mathematically wrong, in
  which case fix the plan first and re-derive the scenes that depend on it. A
  scene repaired by deleting the claim it could not render is a regression.
- **Read the actual error.** Manim's failure text names the file, the line and
  the offending object. Repairing from the symptom ("it looked wrong") wastes a
  render.
- **After five failures, simplify.** Fewer simultaneous objects, shorter formulas,
  one animation per beat. Three failing repairs mean the scene is trying to do
  too much in one shot, not that the API is unlucky.
- **Draft cheap, finish expensive.** Render drafts at `-ql` (480p15) while
  iterating; only the final cut needs `-qh`. The source method renders everything
  at 1080p60 from the start and pays for it — their whole study cost roughly
  USD 1500 in API calls alone, and every wasted render is time added to that.
- **Re-render only what broke.** `render.py --only scene-03` after a fix; a
  full re-render on every edit is the most common way this pipeline becomes
  unbearable.

## Stage 5 — assembly

Order comes from the plan, never from the file system. Their assembler refuses to
combine at all when the number of rendered scenes does not match the outline, and
that refusal is correct: a film with a missing scene is not a film.

- Join as a stream copy when the clips agree on codec, size and frame rate; fall
  back to one re-encode (with padding) when they do not — the scripts do this
  automatically.
- If some clips carry audio and others do not, the silent ones need a silent
  track before concatenation, or the join fails. `assemble.py` handles this by
  re-encoding with a single audio map when `--audio` is given.
- Subtitles from per-scene `.srt` files must be offset by the accumulated duration
  of the preceding scenes; burn them in, or ship them alongside.
- Output spec worth aiming at: **1920×1080**, 30 or 60 fps, H.264, `+faststart`.

## How this skill differs from the source implementation

Deliberate changes, each for a reason:

| Source | Here | Why |
|---|---|---|
| Three model calls per scene (planner ×3, coder) | the agent writes all three parts itself, in one plan file | one agent already holds the whole argument; three calls would only add coordination cost |
| XML tags parsed with regex (`<SCENE_OUTLINE>`, `<SCENE_VISION_STORYBOARD_PLAN>`) | one JSON plan | simpler to validate, and the agent reads it back |
| Renders directly at `-qh` 1080p60 | `-ql` draft gate, then `-qh` final | their retry loop pays 1080p60 cost on scenes that are about to be thrown away |
| TTS narration inside the render (`manim-voiceover` + Kokoro) | narration as subtitles **and** a real voice track via the DSH TTS host route (`scripts/tts_narration.py` → `assemble.py --audio`) | their in-render TTS is unusable here, but the plugin's host route returns mp3 bytes; subtitles are still burned so the film works muted |
| RAG over Manim documentation | not used | their own ablation shows RAG *hurts*: 93.8 % → 82.1 % render success for one model, 55.0 % → 45.8 % for another |
| LLM-as-judge scoring (`eval_suite`, five axes, geometric mean) | the same five axes as a self-review checklist | no judge model here; the checklist keeps the rating calibrated |
| macOS/Linux only, untested on Windows | Windows-specific notes in `SKILL.md` | this environment is Windows; their README explicitly excludes it |

Their code also has known defects in the optional visual-repair path (an
undefined `self.scene_model`, a prompt `.format()` whose placeholders do not
match, and a repair loop with no global cap). Nothing from that path is
reproduced here; the repair loop in this skill is the plain error-driven one.

## What the plan file must survive

A plan is finished when, without opening a single scene file, someone can tell:

1. what the answer is (`answer`, `theorem`);
2. what each scene claims and in what order (`scenes[].purpose`, `equation`);
3. how long the film should be (`assembly.planned_total_seconds`);
4. what "done" means (`review_criteria`, `scenes[].check`).

If any of those four needs the code to be read, the plan is not finished.
