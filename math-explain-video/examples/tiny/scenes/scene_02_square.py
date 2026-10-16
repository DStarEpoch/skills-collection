"""Example scene 2 — promote the example to an identity, then check it back.

Same helper block as scene 1 on purpose: this package's visual consistency rule
is enforced by reusing the helpers in every file, not by remembering to be
consistent.
"""

from manim import *  # noqa: F403

INK = "#e8e8e8"
ACCENT = "#ffd166"
DIM = "#9a9a9a"
RULE = "#4a4a4a"
BACKGROUND = "#101010"

config.background_color = BACKGROUND


def pick_font(candidates=("Microsoft YaHei", "Noto Sans CJK SC", "PingFang SC", "Source Han Sans SC")):
    try:
        from manimpango import list_fonts
        available = set(list_fonts())
    except Exception:
        return None
    for name in candidates:
        if name in available:
            return name
    return None


CJK = pick_font()


def zh(text, size=34, color=INK, weight=NORMAL, line_spacing=0.6):
    kwargs = {"font_size": size, "color": color, "weight": weight, "line_spacing": line_spacing}
    if CJK:
        kwargs["font"] = CJK
    return Text(text, **kwargs)


def mtex(latex, size=48, color=INK):
    return MathTex(latex, font_size=size, color=color)


def title_bar(chapter, heading):
    number = zh("%02d" % chapter, size=24, color=DIM)
    label = zh(heading, size=30, color=INK)
    row = VGroup(number, label).arrange(RIGHT, buff=0.35, aligned_edge=DOWN)
    row.to_corner(UL, buff=0.6)
    rule = Line(LEFT, RIGHT, color=RULE, stroke_width=1.5)
    rule.width = config.frame_width - 1.2
    rule.next_to(row, DOWN, buff=0.18).align_to(row, LEFT)
    return VGroup(row, rule)


class Scene02Square(Scene):
    def construct(self):
        bar = title_bar(2, "一般情形：n 的平方")
        self.play(FadeIn(bar), run_time=0.6)
        self.wait(0.4)

        identity = mtex(r"1 + 3 + \cdots + (2n-1) = n^2", size=52)
        check = mtex(r"n = 4:\quad 16 = 4^2", size=44, color=ACCENT)
        block = VGroup(identity, check).arrange(DOWN, buff=0.9).move_to(UP * 0.6)

        self.play(Write(identity), run_time=1.4)
        self.wait(1.0)
        self.play(Write(check), run_time=1.2)
        self.wait(0.8)
        self.play(Indicate(check, color=ACCENT, scale_factor=1.05), run_time=0.9)
        self.wait(2.6)
