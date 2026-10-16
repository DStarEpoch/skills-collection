# Requirements, portability traps and the optional TTS route

Everything in this package is harness-neutral. This file records what a machine
must provide, the traps that have already cost time on real machines, and the
HTTP contract `scripts/tts_narration.py` speaks when narration audio is wanted.

## 1. What the machine must provide

| Need | Check command | Why |
|---|---|---|
| Python ≥ 3.11 | `python -V` | Manim 0.22 will not install on 3.9/3.10 |
| Manim Community 0.22.x | `python -m manim --version` | rendering; keep it in a project venv with a lockfile |
| ffmpeg + ffprobe | `ffmpeg -version`, `ffprobe -version` | `check_video.py` and `assemble.py` need both; `libass` in the build is what burns subtitles |
| LaTeX (optional) | `kpsewhich standalone.cls amsmath.sty` | only when a scene uses `MathTex`/`Tex`; the whole film can be built with `Text` alone |
| A CJK font (optional) | `fc-list :lang=zh` (Linux) or just try it | `Text` with CJK needs a font that exists; the skeleton's `pick_font()` tries `Microsoft YaHei`, `Noto Sans CJK SC`, `PingFang SC`, `Source Han Sans SC` |

`python scripts/selftest.py` exercises the first three end to end.

## 2. Portability traps already paid for

- **`--sub-margin` is not pixels.** It becomes ASS `MarginV`, which libass
  measures against a 384×288 script resolution, so `40` places the top of a
  one-line subtitle at roughly y = −2.4 in the 8-unit Manim frame. Scene content
  that reaches below y ≈ −2.4 collides with burned subtitles.
- **Windows consoles garble Manim's box-drawing output.** `render.py` sets
  `PYTHONUTF8=1` and `PYTHONIOENCODING=utf-8` for the child and decodes as UTF-8;
  keep that if you re-implement a stage.
- **Never read redirected `ffprobe` output from a file on Windows.**
  PowerShell's `>` writes UTF-16 and the BOM breaks JSON parsing. Capture the
  subprocess output (the scripts do) or decode with `utf-8-sig`.
- **`-qh` is the default** when no `-q` is passed, so an unqualified render is
  1080p60 and feels slow. Iterate at `-ql`.
- **`-c` means `--config_file`, not a colour**; the background is
  `config.background_color` or `--background_color`.
- **A file with several `Scene` classes and no class name given makes the Manim
  CLI wait on stdin**, which looks exactly like a hang. Always pass the class
  name (all the scripts here do, with `stdin=DEVNULL` on the child).
- **Readability beats elegance in a layout**: a text line wider than the 14.22-unit
  frame is cut off at the edge, and CJK glyphs are wider than they look. Look at
  the extracted frames — a render that "succeeded" can still be cropped.

## 3. Optional: the narration TTS route

`scripts/tts_narration.py` drives an HTTP service that synthesises speech on the
machine (not inside Manim). `--base` resolves in this order:

1. `--base <url>`
2. `$TTS_BASE_URL`
3. the harness's own base URL variable (`$DSH_WEB_URL` on the reference implementation)
4. `http://127.0.0.1:19387`

### The contract (five endpoints)

| Call | Body / query | Response |
|---|---|---|
| `POST /dsh-tts-api/diagnose` | `{}` | `{ ok, checks: [{ id, ok, detail }] }` — the script requires the check with `id == "edge"` (or your provider's id) to be `ok` |
| `POST /dsh-tts-api/speak` | `{ text, voice, provider, prosody: { rate, pitch, volume } }` | short text → `{ url }`; long text → `{ jobId, chunks: [url], total }` |
| `GET /dsh-tts-api/rvc-next?job=<id>` | — | `{ url, more }` | `{ done: true }` — pull the remaining chunks in order |
| `GET /dsh-tts-audio/<id>` | — | the audio bytes (`audio/mpeg`) |
| `GET /dsh-tts-api/notify?s=<n>` | — | (reference implementation only) alert-driven playback |

`prosody.rate` is written straight into SSML, so it takes percentage strings such
as `-5%`. argparse will not accept `--rate -5%` as a value (it looks like an
option); the script rewrites it, and `--rate=-5%` always works.

### Reference implementation (optional, not required)

The route was developed against **`dsh-plugin-tts`**, a DSH client plugin: it
synthesises on the host so the audio can be fetched as bytes, and the front end
only plays it. Measured on that implementation (2026-10-15):

- `diagnose` reports `edge: ok`, ~2.3 s for a first synthesis;
- `speak` returns **mp3, 24 kHz, mono** (a 25-character Chinese sentence → 31,680
  bytes, 5.28 s);
- Chinese at `rate: -5%` runs at **≈5.1 characters/second** (656 characters →
  128.3 s), which is why the plan's "4–5 characters per second" drafting rule is
  honest — when a scene's picture is much shorter than its take, the scene was
  planned too tight rather than the voice being slow;
- the local RVC / Index-TTS2 / CosyVoice / Google Cloud backends are off unless
  configured, so the default path needs no API key.

If your harness has no such route, skip the audio entirely: `scripts/make_srt.py`
plus `assemble.py --burn-subs` produce a complete, usable film.
