# Manim cookbook for generated explainers

The reliable subset. Written for code that a model writes and a script renders
without a human watching — so it favours the API that has been stable for years
and the CLI flags whose behaviour is documented, and it lists the failures you
will actually meet.

Target: **Manim Community 0.22.x**, the current stable line, on **Python ≥ 3.11**
(3.11–3.14). Community edition, not `manimgl`: community has versioned releases,
a changelog and a deprecation process, while `manimgl` documents breaking changes
as unannounced. Always invoke it as `python -m manim` so a `manimgl` install
cannot shadow the `manim` command.

## Install and health-check

```sh
uv init --python 3.13 math-videos     # Manim 0.22 needs Python >= 3.11
cd math-videos
uv add "manim==0.22.*"                # isolated .venv + uv.lock in the project
uv run manim --version                # first line: "Manim Community v0.22.x"
uv run manim checkhealth              # answer 'n' to the offered test render
```

Prefer a project environment over a global install: a lockfile next to the scenes
is what keeps a regenerated video reproducible weeks later, and it keeps Manim out
of a shared interpreter (this machine's conda *base* env, for instance). Without
`uv`, `python -m venv .venv` plus `pip install "manim==0.22.*"` is the same idea
done by hand. Manim ships a `manim` console script; since 0.19 it does **not** need
an external ffmpeg (it uses PyAV), but this pipeline's checking and joining
scripts do.

`checkhealth` is the fastest way to find a broken LaTeX or Cairo install. It asks
a question on stdin when everything passes, so in a script feed it `n` — otherwise
it looks like a hang. (It is not confirmed to exit non-zero on a failed check, so
read its output rather than trusting its exit code.)

What still has to be installed **for this pipeline**, even though Manim no longer
needs it: **ffmpeg + ffprobe** (the checking and joining scripts). **LaTeX** is
needed only when a scene uses `Tex`/`MathTex`; `Text` does not touch LaTeX
(ManimPango bundles its own Pango, so no `pango-view` binary is required).

| Platform | LaTeX / system packages |
|---|---|
| Debian/Ubuntu | `texlive-full`, or `texlive-latex-extra` + `texlive-science` for `standalone.cls`; plus `build-essential python3-dev libcairo2-dev libpango1.0-dev` |
| macOS | official MacTeX (the Homebrew build shipped a broken `dvisvgm` 3.6 — reported in issue #4632, not verified here) |
| Windows | TeX Live or MiKTeX, plus MSVC Build Tools if a wheel has to be built |

Verify LaTeX conversion directly when a formula fails for no visible reason:

```sh
kpsewhich standalone.cls preview.sty amsmath.sty       # must all print a path
dvisvgm --version && dvisvgm -l | grep -i ps           # should list PostScript specials
```

## The minimum runnable scene

```python
from manim import *

class Demo(Scene):
    def construct(self):                      # exactly this spelling
        title = Text("Pythagoras", font_size=28)
        formula = MathTex(r"a^2 + b^2 = c^2", font_size=44)
        stack = VGroup(title, formula).arrange(DOWN, buff=0.5).move_to(ORIGIN)
        self.play(FadeIn(title), run_time=0.6)
        self.play(Write(formula), run_time=1.2)
        self.wait(1.0)
```

```sh
python -m manim -ql demo.py Demo          # 854x480@15, seconds, for layout checks
python -m manim -qh --fps 30 demo.py Demo # 1920x1080@30, the final cut
```

`construct` misspelled, or a scene name that does not match the class, produces
**exit code 0 with a black screen** — the single most common silent failure in
this whole workflow. That is why the pipeline checks the rendered frames, not
just the exit code.

## CLI: what actually happens

| Flag | Meaning |
|---|---|
| `-ql` / `-qm` / `-qh` / `-qp` / `-qk` | 854×480@15 / 1280×720@30 / **1920×1080@60** / 2560×1440@60 / 3840×2160@60. Without `-q` you get `-qh`. |
| `--fps N` (alias `--frame_rate`) | override the preset's frame rate — how you get 1080p30 |
| `-o name` | output file name (the clip becomes `name.mp4`) |
| `-s` | render only the last frame as PNG (`--format=png`); a cheap layout check |
| `--format` | `auto`/`none`/`png`/`png-sequence`/`gif`/`mp4`/`webm`/`mov` |
| `--media_dir DIR` | where `videos/`, `images/`, `Tex/` and the cache live |
| `-v WARNING` … `-v DEBUG` | verbosity; `WARNING` keeps render logs readable |
| `--disable_caching` | ignore partial-movie cache; use it when a repair seems not to take effect |
| `-n <start>,<end>` | render an animation range only |
| `--dry_run` | set up the scene without rendering |

Traps confirmed in the source:

- **`-c` is `--config_file`, not a colour.** Recipes that say `manim -c WHITE` are
  from another era; use a `config.background_color` in the file or the
  `--background_color` option.
- **An illegal `-n` or `--resolution` exits with code 0** (a bare `sys.exit()` in
  the CLI), so a zero exit code proves nothing on its own.
- **Several scenes in one file with no scene name given makes the CLI wait on
  stdin** (`Choice(s): `). Always pass the class name, and give a child process
  `stdin=DEVNULL` so a prompt fails instead of hanging.
- **`-o` is rejected when more than one scene is selected**: `--output_file can
  only be used when rendering exactly one scene. Remove --write_all or select a
  single scene.` One scene per render call, which is what this pipeline does.
- **`--format=auto` degrades to a last-frame PNG** for a scene that contains no
  `play`/`wait`, and warns instead of failing. Always pass `--format=mp4`.
- There is no `--flush_cache`; clear with `python -m manim cache clear file.py Scene`.

Exit codes, so a runner can tell the failures apart:

| Situation | Exit code |
|---|---|
| an exception while rendering | **1** |
| CLI usage error (unknown flag, `--format` not in the enum) | **2** |
| illegal `-n` / `--resolution` | **0** (silent) |
| killed for memory (Linux OOM) | **137** |

Because of all that, treat a render as successful only when **all four** hold:
exit code 0, `File ready at '<path>'` present in the log, that file exists and is
non-empty, and `ffprobe` reads a duration greater than zero. `scripts/render.py`
does exactly this.

Sanity-check the interpreter before blaming a scene: `python -m manim --version`
must print `Manim Community v0.22.0` on its first line. If it says something else
you are running `manimgl`, and none of the API in this file applies.

## Where the files land

```
media/videos/<script_stem>/<quality_dir>/<SceneName>.mp4      # 480p15 / 720p30 / 1080p60 / 1440p60 / 2160p60
media/images/<script_stem>/<SceneName>_ManimCE_v<version>.png # with -s
media/Tex/<hash>.log                                          # LaTeX logs when a formula fails
```

`--save_sections` also writes `sections/<Scene>_0000_<name>.mp4` plus a JSON with
width, height, `avg_frame_rate`, duration and frame count — more reliable than
parsing directory names when you need exact metadata. When you need the layout on
disk to be stable across projects, put a `manim.cfg` next to the scene files:

```ini
[CLI]
media_dir = project-media
video_dir = {media_dir}/renders/{module_name}/{quality}
partial_movie_dir = {video_dir}/partial_movie_files/{scene_name}
```

## Text, formulas and CJK

- **`MathTex` for mathematics, `Text` for everything else, never mixed.**
- **CJK goes in `Text`, with a font that exists**: `Text("结论", font="Microsoft YaHei")`
  on Windows, `Noto Sans CJK SC` on Linux, `PingFang SC` on macOS. `MathTex`
  cannot typeset Chinese. To mix words into a formula, use `\text{}`:
  `MathTex(r"\text{Area} = \pi r^2")`.
- **Prefer `Text` even for simple mathematics** if LaTeX is unavailable: Unicode
  covers `x² + y² = r²`, `√`, `∑`, `∫`, `α β γ`. What you lose is real fractions,
  radicals with vinculum, matrices, and `\sum` limits above and below the sign —
  when the explanation depends on those, LaTeX (or Typst) is worth installing.
- **`MarkupText`** gives inline colour and underline through Pango markup
  (`<span fgcolor="#ffd166">`), which covers most "highlight this word" needs
  without LaTeX.
- **`Typst` / `MathTypst`** (Manim 0.22 with the `manim[typst]` extra) typesets
  mathematics without any TeX installation — the fallback when a machine cannot
  carry a LaTeX distribution.
- Using `Tex` for Chinese needs a CJK LaTeX template (`TexTemplateLibrary.ctex`,
  `ctex` + XeLaTeX), and that path has known defects: `BraceLabel` with `ctex`
  raising `IndexError: list index out of range` (issue #3254) and baseline
  misalignment in mixed CJK/Latin text (issue #3262). Prefer `Text` for CJK and
  keep `Tex`/`MathTex` pure mathematics.
- **`TransformMatchingTex`** only matches sub-strings it can isolate: wrap them in
  `{{ }}` or pass `substrings_to_isolate`, or the transform silently does nothing
  useful.
- **Brace splitting in `MathTex`**: `{{ ... }}` groups a sub-string, and an
  unbalanced brace gives `! Missing } inserted.` (the rule was tightened in 0.20;
  issue #4612). Keep formulas simple and balanced.
- Font sizes that survive video compression: **title 28, side labels and formulas
  24**. More than ~10 words on a line: wrap into several lines rather than shrink.
- `Triangle` is equilateral; for a right triangle use `Polygon`.

## Animation vocabulary worth using

`FadeIn`, `FadeOut`, `Create`, `Uncreate`, `Write`, `Transform`,
`ReplacementTransform`, `Indicate`, `Circumscribe`, `GrowArrow`, `LaggedStart`,
`AnimationGroup`, `Wait`.

- **`Transform` needs matching structure** (same number of points/submobjects);
  when the shapes differ, use `ReplacementTransform`. A `Transform` between
  unrelated mobjects is a classic silent-looking glitch.
- **Removed or renamed long ago** (never generate them): `ShowCreation`,
  `TextMobject`, `TexMobject`, `ShowPassingFlash`. `Create`/`Text`/`Tex` are the
  current names. (The exact removal versions are not documented in the
  changelogs I could reach — just do not emit them.)
- One new object group per `self.play`, `run_time` 0.5–2 s, then a `self.wait()`
  of 0.6–1.5 s. Ending a scene on its last animation reads as truncated.
- Keep an empty `VGroup` out of `self.play`: it silently does nothing.

## Layout vocabulary

- The 16:9 frame is **14.22 × 8.00 units** centred on `(0, 0, 0)`: keep x within
  ±7 and y within ±4.
- **Safe-area margin 0.5 units; minimum spacing between objects 0.3 units**, edge
  to edge. These are the source method's hard constraints, and they are the ones
  that keep generated scenes from colliding.
- **Relative positioning only**: `next_to`, `align_to`, `shift`, `to_edge`,
  `to_corner`, `move_to(ORIGIN)`, plus `VGroup(...).arrange(...)`. Absolute
  coordinates are the root cause of off-frame content.
- Do not create a coloured background rectangle; set the background once, and
  never paint text black on a dark theme.

## LaTeX packages

Anything beyond Manim's default template must be declared, or the render dies on
a missing command:

```python
template = TexTemplate()
template.add_to_preamble(r"\usepackage{amssymb}")
formula = MathTex(r"\sqrt{2} \notin \mathbb{Q}", tex_template=template, font_size=56)
```

`\mathbb`, `\notin`, `\gcd`, `\therefore` and `\text` are the usual culprits.

**Debugging a formula failure.** Keep the intermediate files and read the log the
error names:

```sh
python -m manim -ql --no_latex_cleanup demo.py Demo     # or: render.py --keep-latex
grep -n -m1 -A3 '^!' media/Tex/*.log                    # the first real LaTeX error
```

A minimal TeX install is the usual cause of `standalone.cls' not found`:
`texlive-latex-extra` covers it on Debian/Ubuntu. TeX Live's own required-package
list, if you use TinyTeX or `tlmgr`:

```text
amsmath babel-english cbfonts-fd cm-super count1to ctex doublestroke dvisvgm everysel
fontspec frcursive fundus-calligra gnu-freefont jknapltx latex-bin mathastext microtype
multitoc physics preview prelim2e ragged2e relsize rsfs setspace standalone tipa wasy
wasysym xcolor xetex xkeyval
```

`! LaTeX3 Error: Mismatched LaTeX support files detected.` means two TeX trees are
mixed (a system install plus a hand-installed package): put one distribution on
`PATH`, or `tlmgr update --self --all`.

**For CJK through LaTeX** the ready-made template is
`TexTemplateLibrary.ctex` (needs `ctex` + XeLaTeX), but the known defects above
are why this skill prefers `Text` for Chinese. Check what fonts the machine
actually has before trusting a font name:

```sh
python -c "import manimpango; print([f for f in manimpango.list_fonts() if 'CJK' in f or 'YaHei' in f][:20])"
```

A wrong font name does not raise: Pango falls back silently, which shows up as a
different typeface or as tofu boxes in the extracted frames.

## Graphs and geometry

```python
axes = Axes(x_range=[-3, 3, 1], y_range=[-1, 9, 2], x_length=8, y_length=4.5,
            axis_config={"color": GREY_B, "include_tip": True})
curve = axes.plot(lambda x: x ** 2, color=YELLOW, x_range=[-3, 3])
label = axes.get_graph_label(curve, label=r"y = x^2", x_val=2, direction=UP)
self.play(Create(axes), run_time=1.2)
self.play(Create(curve), run_time=1.6)
```

Keep the axis lengths explicit (`x_length`/`y_length`) instead of letting them
grow: an auto-sized `Axes` is a common way for a label to drift out of frame.

**`Axes` numbers are LaTeX by default.** `get_axis_labels()` and
`axis_config={"include_numbers": True}` compile through LaTeX, so even a scene that
looks like pure geometry fails on a machine without it. Either install LaTeX, or
draw the ticks yourself with `Text`.

## Error → fix

| What you see | What it means | Fix |
|---|---|---|
| `LaTeX compilation error: LaTeX Error: File \`standalone.cls' not found.` | the LaTeX distribution is minimal | install `texlive-latex-extra` (or full TeX Live) |
| `ValueError: latex error converting to dvi. See log output above or the log file: media/Tex/<hash>.log` | bad LaTeX, or a package the template lacks | read that log file; fix the formula or add the package with `TexTemplate.add_to_preamble` |
| `! LaTeX3 Error: Mismatched LaTeX support files detected.` | two TeX installations mixed | put one TeX distribution on `PATH` |
| `latex error converting to dvi` with `dvisvgm` missing | no PDF→SVG converter | install `dvisvgm`; if it is present but broken, set `LIBGS` or move to another TeX distribution |
| `! Missing } inserted.` | unbalanced braces in `MathTex` (often a stray `{{`) | balance the delimiters, split the formula into two |
| `IndexError: list index out of range` with `ctex` | known `BraceLabel` defect | use `Text` for CJK instead of LaTeX |
| black screen, exit code 0 | `construct` misspelled, or a scene that adds nothing | check the method name; check the frames |
| the CLI prints `Choice(s): ` and hangs | several scenes in one file, no scene name passed | always pass the class name; `stdin=DEVNULL` |
| a repair seems not to apply | stale partial-movie cache | `--disable_caching`, or `manim cache clear file.py Scene` |
| import error from `moviepy` in tooling | moviepy 2.x renamed APIs (`from moviepy import VideoFileClip`, `clip.subclipped`) | match the 2.x API, or avoid moviepy and use ffmpeg |
| exit code 137 (Linux) | the process was killed for memory | drop to `-qm`, add `--encoder-queue-size 2` |

OpenGL rendering (`--renderer=opengl`) has documented defects around `VGroup`
layering (issue #4890), `Text` triangulation (issue #4483) and `DecimalNumber`
animation (issue #4097); with `--format=auto` it can exit successfully without
writing a file at all. **Automated pipelines stay on the default Cairo renderer.**
`interactive_embed` raising `sqlite3.ProgrammingError` is a known IPython
incompatibility (the documented workaround is `pip install IPython==8.0.1`).

## Cost, memory and reproducibility

Render cost is roughly frames × pixels, so quality choices are cost choices: `-qk`
costs orders of magnitude more than `-ql` for the same scene. A long
`self.wait(10)` really does render hundreds of frames — keep deliberate pauses to
1–2 seconds and put the long hold at the end of the film only.

| Need | Flag |
|---|---|
| fewer encoder buffers (less memory) | `--encoder-queue-size 2` (default 8) |
| overlap encoding with rendering (faster, more memory) | `--max-inflight-encoders 4` (default 1) |
| identical output across runs | `--seed 0` |
| ignore stale partial renders | `--disable_caching` |
| a hang guard | wrap the call in a timeout: 60 s for `-ql`, 300 s for `-qm`, 900 s for `-qh` |

## Joining clips with ffmpeg

Same codec, size and frame rate — stream copy, instant:

```sh
# list.txt: file '/abs/path/scene-01.mp4'  (one per line, absolute paths, forward slashes)
ffmpeg -y -f concat -safe 0 -i list.txt -c copy out/final.mp4
```

Different sizes or frame rates — normalise every clip first, then join. The
`setsar=1` matters: mismatched sample aspect ratios make the concat demuxer
produce broken timestamps even when the pixel dimensions agree.

```sh
ffmpeg -y -i scene.mp4 -vf "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,fps=30,setsar=1" \
  -c:v libx264 -crf 18 -pix_fmt yuv420p -c:a aac scene-norm.mp4
```

The `concat` *filter* is the alternative for a single pass, but it cannot be
combined with `-c copy`, and it needs every input alive at once — for a handful of
scenes the demuxer path above is simpler to debug. Adding audio to an otherwise
silent film: give it to the join as a single `-i` track, or pad silent clips with
`anullsrc=channel_layout=stereo:sample_rate=44100` so a shared audio map exists.

## Automated checks that actually catch things

```sh
# a frame at a chosen time (-ss before -i is fast, after -i is exact)
ffmpeg -y -ss 6.5 -i out/final.mp4 -frames:v 1 shots/frame-6.5.png

# contact sheet: one tile every 5 s, 4x3 grid
ffmpeg -y -i out/final.mp4 -vf "fps=1/5,scale=320:-1,tile=4x3" -frames:v 1 shots/sheet.png

# black stretches: pass d explicitly, the default (2 s) misses short black intros
ffmpeg -hide_banner -i out/final.mp4 -vf "blackdetect=d=0.4:pix_th=0.10" -an -f null - 2>&1 | grep black_start

# metadata
ffprobe -v error -show_entries format=duration \
        -show_entries stream=width,height,r_frame_rate,nb_frames -of default=noprint_wrappers=1 out/final.mp4
```

Text that drifts off the frame edge has no dedicated tool. The ffmpeg-only
approximation is to crop thin border bands and count non-black pixels there:

```sh
ffmpeg -hide_banner -i out/final.mp4 -vf "crop=iw:6:0:0,blackframe=98:32" -an -f null - 2>&1 | grep -c blackframe
```

That catches a band with *something* in it, not whether it is meaningful — which is
why the pipeline still extracts frames and looks at them. `scripts/check_video.py`
wraps the metadata, blank-frame, black/frozen and frame-extraction checks.

## Version drift

Pin Manim (`manim==0.22.*`) in any project that regenerates scenes over weeks. The
0.19 release dropped `inner_radius`/`outer_radius` from `Sector`, renamed
`ManimColor.from_hex(hex=...)` to `hex_str=`, and renamed `next_section(type=...)`
to `section_type=`. Generated code that ignores this renders fine on the machine
that wrote it and fails on the next upgrade.

One correction worth keeping, because the opposite is widely repeated: in 0.22 the
mobject argument of the shape matchers is **positional**. `SurroundingRectangle(mob, color=…, buff=…)`
works and `SurroundingRectangle(mobject=mob, …)` raises
`TypeError: Mobject.__init__() got an unexpected keyword argument 'mobject'` —
verified by rendering both forms against the installed 0.22.0. When a changelog
note and the installed behaviour disagree, the installed behaviour wins: render a
one-line scene and let the traceback settle it.
