"""Scene skeleton for a math explainer. Copy this file per scene and edit.

Why this file looks the way it does (each rule prevents a real failure):

* No quality settings in the file. Resolution and frame rate come from the
  command line (`-ql` draft, `-qh --fps 30` final), because a module-level
  `config.frame_rate` / `config.pixel_width` is applied *after* the CLI and
  silently overrides `-q`. `config.background_color` is the one exception: no
  quality preset touches it, so the film's page colour is safe to fix here.
* `Text` for anything with CJK, `MathTex` for formulas, never mixed: LaTeX
  cannot typeset Chinese without a CJK template, and `Text` cannot typeset
  fractions or radicals.
* One shared ink/accent palette and one shared title bar, so every scene looks
  like the same film (this is the "visual consistency" review criterion, made
  mechanical instead of remembered).
* Layout is measured with `VGroup.arrange` + `move_to`, not with hand-typed
  coordinates, so nothing drifts out of frame at a different resolution.
* Only these animations are used: FadeIn, Create, Write, Transform, Indicate,
  Circumscribe, GrowArrow. They are stable across Manim versions; the rename
  traps (`ShowCreation`, `TextMobject`, `ShowPassingFlash`) are avoided.
* `self.wait()` after every reveal: speech needs time to land, and a scene that
  ends on the last animation looks cut off.

Render it:

    python -m manim render -ql scenes/scene_01_statement.py Scene01Statement
    python -m manim render -qh --fps 30 scenes/scene_01_statement.py Scene01Statement
"""

from manim import *  # noqa: F403  (Manim's public API is star-imported by design)

# ---------------------------------------------------------------- palette ----
INK = "#e8e8e8"        # body text and formulas
ACCENT = "#ffd166"     # the one thing the viewer should look at now
DIM = "#9a9a9a"        # secondary labels
RULE = "#4a4a4a"       # hairlines
BACKGROUND = "#101010"

# Manim renders on a black canvas by default; set the page colour once here so
# every scene matches. The quality presets (-ql/-qm/-qh) never touch this, so it
# cannot fight the command line the way frame_rate would.
config.background_color = BACKGROUND


def pick_font(candidates=("Microsoft YaHei", "Noto Sans CJK SC", "PingFang SC", "Source Han Sans SC")):
    """First installed CJK font, or None to let Manim fall back to its default."""
    try:
        from manimpango import list_fonts  # ships with Manim
        available = set(list_fonts())
    except Exception:
        return None
    for name in candidates:
        if name in available:
            return name
    return None


CJK = pick_font()


def zh(text, size=34, color=INK, weight=NORMAL, line_spacing=0.6):
    """Chinese/plain text. Never put CJK inside MathTex."""
    kwargs = {"font_size": size, "color": color, "weight": weight, "line_spacing": line_spacing}
    if CJK:
        kwargs["font"] = CJK
    return Text(text, **kwargs)


def mtex(latex, size=48, color=INK):
    """A formula. Keep each string short; MathTex fails loudly on bad LaTeX."""
    return MathTex(latex, font_size=size, color=color)


def title_bar(chapter, heading):
    """The same bar at the top of every scene: chapter number, heading, rule."""
    number = zh("%02d" % chapter, size=24, color=DIM)
    label = zh(heading, size=30, color=INK)
    row = VGroup(number, label).arrange(RIGHT, buff=0.35, aligned_edge=DOWN)
    row.to_corner(UL, buff=0.6)
    rule = Line(LEFT, RIGHT, color=RULE, stroke_width=1.5)
    rule.width = config.frame_width - 1.2
    rule.next_to(row, DOWN, buff=0.18).align_to(row, LEFT)
    return VGroup(row, rule)


class Scene01Statement(Scene):
    """One scene = one beat of the argument. Keep it under ~15 s."""

    def construct(self):
        bar = title_bar(1, "定理陈述")
        self.play(FadeIn(bar), run_time=0.6)
        self.wait(0.4)

        claim = mtex(r"\sqrt{2} \notin \mathbb{Q}", size=64, color=INK)
        claim.move_to(ORIGIN)
        self.play(Write(claim), run_time=1.6)
        self.wait(1.0)

        strategy = zh("反证法：先假设它是有理数", size=30, color=ACCENT)
        strategy.next_to(claim, DOWN, buff=0.9)
        self.play(FadeIn(strategy, shift=UP * 0.2), run_time=0.8)
        self.wait(1.8)

        # Leave the scene with both the claim and the plan on screen: the next
        # scene continues from exactly this picture.
        self.play(Indicate(claim, color=ACCENT, scale_factor=1.06), run_time=0.8)
        self.wait(1.2)


class Scene02Assumption(Scene):
    """A second scene in the same file is fine for a quick draft, but the plan
    asks for one file per scene so a failing render only costs that scene."""

    def construct(self):
        bar = title_bar(2, "反证假设")
        self.play(FadeIn(bar), run_time=0.6)

        assumption = mtex(r"\sqrt{2} = \frac{p}{q}", size=64)
        assumption.move_to(UP * 0.6)
        self.play(Write(assumption), run_time=1.4)

        coprime = zh("p、q 互质，q ≠ 0", size=32, color=ACCENT)
        # keyword arguments on purpose: Manim 0.19 made these parameters
        # keyword-only, and positional calls now raise
        # the mobject goes in positionally: Manim 0.22 rejects mobject= as a keyword
        # ("Mobject.__init__() got an unexpected keyword argument 'mobject'"), and its
        # own docstring example passes it that way
        box = SurroundingRectangle(coprime, color=ACCENT, buff=0.18, stroke_width=2)
        group = VGroup(coprime, box).next_to(assumption, DOWN, buff=0.8)
        self.play(FadeIn(group), run_time=0.8)
        self.wait(1.0)
        self.play(Circumscribe(coprime, color=ACCENT, run_time=1.0))
        self.wait(1.6)


class FunctionPlot(Scene):
    """The pattern for graphs: axes first, then the curve, then the label.

    Use this shape when the explanation is about a function's behaviour rather
    than a chain of equations. `Axes.plot` takes a Python lambda, so the maths
    stays visible in the code and the readout can be driven from the same lambda.
    """

    def construct(self):
        axes = Axes(x_range=[-3, 3, 1], y_range=[-1, 9, 2], x_length=8, y_length=4.5,
                    axis_config={"color": DIM, "include_tip": True})
        # get_axis_labels() and include_numbers compile through LaTeX: a scene that
        # looks like pure geometry still fails without a TeX install. Without one,
        # place Text() labels yourself instead.
        labels = axes.get_axis_labels(x_label="x", y_label="y")
        curve = axes.plot(lambda x: x ** 2, color=ACCENT, x_range=[-3, 3])
        tag = axes.get_graph_label(curve, label=r"y = x^2", x_val=2, direction=UP)
        self.play(Create(axes), FadeIn(labels), run_time=1.2)
        self.play(Create(curve), run_time=1.6)
        self.play(FadeIn(tag), run_time=0.6)
        self.wait(1.5)
