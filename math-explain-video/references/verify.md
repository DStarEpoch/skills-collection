# Verify

What "done" means for a math explainer, in the order you should check it. The
five axes and their questions are quoted from TheoremExplainBench, the benchmark
shipped with the source method — they are the dimensions its authors consider the
measure of an explanation video, so they are the right self-review rubric here.

## Gate 1 — it rendered, and it is not blank

```sh
python scripts/check_video.py out/final.mp4 --frames 8 --sheet out/sheet.png --json out/report.json
```

Read the report, do not skim it:

- **structureless sampled frames** — no spread across the picture at all, which
  means a scene rendered nothing. This is the failure the eye misses on a dark
  theme and the script catches. Note that "dark" is *not* the test: a mostly-black
  frame full of white text is a perfectly good explainer frame, so the check is
  the spread, not the mean.
- **black or frozen stretches are notes, not verdicts** — `blackdetect` and
  `freezedetect` are luminance heuristics and a dark theme defeats both (Manim's
  default page is black). A hold under a few seconds is a pause to read an
  equation; a long one is worth checking in the frames. Only the structureless
  test decides whether a scene actually rendered.
- **resolution and frame rate** — a draft rendered at 480p15 must never be the
  final cut.
- **audio** — with `--expect-audio` when the plan promised narration; otherwise
  silence is fine.

## Gate 2 — the film matches the plan

`render.py` prints, per scene, the rendered duration against the planned one, and
the plan's `assembly.planned_total_seconds` against the real footage. Ratios
outside **0.8–1.25** mean the animation and the narration disagree: either the
scene is rushed (narration longer than animation) or padded (animation longer
than anything said). Fix the shorter of the two.

## The five axes

Score each 1–5 and fix anything at 3 or below.

| Axis | The question the benchmark asks | How you check it here |
|---|---|---|
| **Accuracy and Depth** | Does the narration explain the theorem accurately? Does the video provide intuitive and/or rigorous explanations for why the theorem holds? | reread every equation as text against your step-1 solution; confirm each scene carries both the rigorous step and the reason it is true |
| **Logical Flow** | Does the video follow a clear and logical structure? Does the video present a coherent buildup of ideas? | read the contact sheet as a storyboard: setup → steps → result → conclusion, each scene handing off to the next |
| **Visual Relevance** | Does the video frame align with the theorem's concepts and derivations? | for each scene, does the frame at the moment of the claim show *that* claim? decorative graphics during a derivation fail |
| **Element Layout** | Are the visual elements well-placed and appropriately sized? Are they free of unintentional overlap? Is the information clear and easy to understand? | 1:1 frames: text collisions, content clipped at the frame edge, type below reading size, three objects fighting for the same space |
| **Visual Consistency** | Does the visual style remain consistent across frames? Are motions and transitions smooth? | same palette and title bar everywhere; one accent colour meaning the same thing; no jump cuts in style between scenes |

Likert anchors, so a "4" means the same thing every time:

```
1 Very poor quality, completely fails to meet the criteria.
2 Below average, significant issues present.
3 Acceptable, meets the basic criteria with minor issues.
4 Good, performs well with no major issues.
5 Excellent, fully meets or exceeds expectations.
```

**Calibration warning.** The benchmark's automated judges track human raters well
on visual relevance, but poorly on the text-only axes (accuracy and depth,
logical flow) — the figures circulating in secondary summaries of the paper put
the rank correlation around 0.7 for visual relevance and around 0.1–0.2 for the
text axes. Translation: an automated opinion about *layout* is worth something,
an automated opinion about *whether the mathematics is right* is worth almost
nothing. Reread the mathematics yourself.

## Reading a contact sheet

`--sheet` tiles the film into one image. Read it as a storyboard, in order:

1. **Does the arc exist?** Title, setup, steps, result, conclusion — a film whose
   last tile looks like its third has no ending.
2. **Does every tile earn its place?** A tile that shows the same picture as its
   neighbour means a scene that does not advance the argument; cut or merge it.
3. **Is the last tile the conclusion?** The final frame should contain the result,
   not the previous step.
4. **Is the density even?** If one tile is a wall of text and the next is nearly
   empty, the plan's pacing is off, not the renderer's.

Then go back to the individual frames for anything suspicious.

## Element-layout traps in machine-written Manim

This axis scores lowest in the source benchmark for a reason. Check these
specifically; all five are invisible in the code and obvious in a frame:

- **Text bounding-box overflow.** A `Text` longer than expected runs past the
  frame edge; `MathTex` with a long fraction is much wider than the source line
  suggests. Fix by wrapping into several lines, not by shrinking the font below
  ~24.
- **Unintentional overlap.** Two groups arranged independently land on top of
  each other. Fix with one `VGroup(...).arrange(...)` that owns both, or by
  explicit `next_to` chains — never by nudging one with hand coordinates.
- **Off-frame drift.** Content placed relative to something that itself grew
  (a long formula, a tall axis) pushes the group out. Check the extremes at the
  moment of maximum content.
- **Type too small.** Side labels and formulas belong at 24, titles at 28; below
  that, phone viewers cannot read them.
- **Empty frames.** An animation that fades the old content before the new
  content arrives leaves a beat of nothing. Overlap the transition instead.
- **Collision with burned subtitles.** Subtitles sit in the bottom ~1.2 units.
  Bottom-anchored scene content (an answer line, a complexity note) overlaps them,
  and because both are text it reads as a smudge rather than two objects. Check the
  final cut at the moment the bottom line appears, not just the scene clips; fix by
  raising the content (`to_edge(DOWN, buff=2.2)` and up) or by
  `assemble.py --sub-margin`.

## Timing

Narration sets the clock. Roughly:

- Chinese: **4–5 characters per second** — 12 s ≈ 40–50 characters.
- English: **2.5–3 words per second** — 12 s ≈ 30–36 words.
- Add **0.6–1.5 s** of silence after each reveal, and **2 s** at the end of the
  film so the conclusion lands.
- If a scene needs to be read rather than heard (a dense derivation), give it the
  time a reader needs, not the time a speaker would take.

## Anti-patterns that got explainers rejected

- **Animating an unsolved problem.** If the mathematics was not settled first,
  the video encodes the mistake and every later repair costs a render.
- **One 90-second scene.** Unverifiable and unmaintainable; split by argument step.
- **Silent scenes / static narration.** A scene with no narration, or narration
  with no visual change, is dead time.
- **Decorative motion.** Rotation, particles or camera moves that carry no claim.
- **Describing instead of teaching.** Narration that narrates the animation
  ("now the box moves right") instead of the mathematics.
- **Shipping the draft.** `-ql` is 480p15 and 15 fps; it is a proof of concept,
  never a deliverable.
- **Trusting the checker.** `check_video.py` finds blank and over-long clips, not
  wrong mathematics and not text sliding off screen. Those need eyes on frames.
- **Trusting the plan's durations.** They are intentions. Only the rendered
  footage is true.
