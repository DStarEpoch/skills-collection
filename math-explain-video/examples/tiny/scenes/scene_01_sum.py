"""Example scene 1 — a concrete sum, short enough to check by eye.

This exists so `scripts/selftest.py` has something real to render on a new
machine. It follows the same shape as `assets/scene_skeleton.py`: the shared
palette, the shared title bar, and only the safe animation set.
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


class Scene01Sum(Scene):
    def construct(self):
        bar = title_bar(1, "把奇数配成平方")
        self.play(FadeIn(bar), run_time=0.6)
        self.wait(0.4)

        claim = mtex(r"1 + 3 + 5 + 7 = 16", size=56)
        claim.move_to(UP * 0.5)
        self.play(Write(claim), run_time=1.2)
        self.wait(0.8)

        caption = zh("前 4 个奇数", size=26, color=DIM)
        caption.next_to(claim, DOWN, buff=0.8)
        self.play(FadeIn(caption, shift=UP * 0.15), run_time=0.7)
        self.wait(2.5)
