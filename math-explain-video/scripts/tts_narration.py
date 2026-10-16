#!/usr/bin/env python3
"""Turn a plan's narration scripts into real audio, via the local TTS host route.

Speech synthesis is often owned by a *harness* process rather than by the agent,
and the audio is then reachable over HTTP on the running app. The route this
script speaks is a five-endpoint contract (see references/environment.md):

    POST /dsh-tts-api/diagnose   {}                        -> provider health
    POST /dsh-tts-api/speak      {text, voice, provider,
                                  prosody:{rate,pitch,volume}}
                                  -> { url }  (short text)
                                  -> { jobId, chunks:[url], total }  (long text)
    GET  /dsh-tts-api/rvc-next?job=<id>                    -> { url, more } | { done }
    GET  /dsh-tts-audio/<id>                               -> audio bytes

This script drives that, one file per scene, then reports each scene's audio
duration against the rendered clip so the two can be reconciled:

    python tts_narration.py plan.json --out out/tts --clips out/final-scenes --pad --concat
    python tts_narration.py plan.json --voice zh-CN-XiaoxiaoNeural --rate -5%
    python tts_narration.py plan.json --dry-run          # list what would be spoken
    python tts_narration.py plan.json --check            # only test the route

Exit codes: 0 ok, 2 = no TTS route (fall back to subtitles only), 1 = failure.

Requires: a running host that implements the route (Edge TTS, which the reference
implementation uses, needs no API key), plus ffmpeg/ffprobe on PATH for measuring,
padding and joining. Nothing outside the standard library is imported.
"""

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import urllib.error
import urllib.request

FFMPEG = os.environ.get("FFMPEG", "ffmpeg")
FFPROBE = os.environ.get("FFPROBE", "ffprobe")
UA = {"User-Agent": "dsh-tts-narration/1.0", "Content-Type": "application/json"}


# ----------------------------------------------------------------- transport --
def http(url, body=None, method=None, timeout=180):
    """(status, headers, bytes); HTTP errors come back as status, not exceptions."""
    data = json.dumps(body).encode("utf-8") if body is not None else None
    request = urllib.request.Request(url, data=data, headers=UA, method=method)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, dict(response.headers), response.read()
    except urllib.error.HTTPError as exc:
        return exc.code, dict(exc.headers or {}), exc.read()
    except Exception as exc:  # noqa: BLE001 - connection refused, timeouts, DNS
        return None, {}, str(exc).encode()


def probe_duration(path):
    proc = subprocess.run([FFPROBE, "-v", "error", "-show_entries", "format=duration",
                           "-of", "default=noprint_wrappers=1:nokey=1", path],
                          capture_output=True)
    try:
        return round(float(proc.stdout.decode("utf-8-sig").strip()), 2)
    except ValueError:
        return None


def ffmpeg(args):
    proc = subprocess.run([FFMPEG, "-y", "-v", "error"] + args, capture_output=True)
    return proc.returncode, proc.stderr.decode("utf-8", "replace").strip()


# ---------------------------------------------------------------------- tts ----
class TtsError(RuntimeError):
    pass


def diagnose(base):
    """Return (ok, checks). ok means the edge provider answered."""
    status, _headers, raw = http(base + "/dsh-tts-api/diagnose", body={}, timeout=60)
    if status != 200:
        raise TtsError("no TTS host route at %s (status=%s)" % (base, status))
    try:
        payload = json.loads(raw.decode("utf-8", "replace"))
    except ValueError:
        raise TtsError("diagnose did not return JSON")
    checks = payload.get("checks") or []
    edge = next((item for item in checks if item.get("id") == "edge"), None)
    return bool(edge and edge.get("ok")), checks


def speak(base, text, provider, voice, rate, workdir, tag, force):
    """Synthesise one text block; return the path of a single mp3 for it."""
    target = os.path.join(workdir, tag + ".mp3")
    if os.path.exists(target) and not force:
        return target, "cached"

    body = {"text": text, "provider": provider}
    if voice:
        body["voice"] = voice
    if rate:
        body["prosody"] = {"rate": rate}
    status, _headers, raw = http(base + "/dsh-tts-api/speak", body=body, timeout=300)
    if status != 200:
        raise TtsError("speak failed (status=%s): %s" % (status, raw.decode("utf-8", "replace")[:200]))
    try:
        reply = json.loads(raw.decode("utf-8", "replace"))
    except ValueError:
        raise TtsError("speak did not return JSON")
    if reply.get("error"):
        raise TtsError("speak error: %s" % reply["error"])

    urls = []
    if reply.get("url"):
        urls.append(reply["url"])
    elif reply.get("jobId"):
        # long text: the reply carries the chunks already synthesised, the rest
        # arrive one at a time until { done: true }
        urls.extend(reply.get("chunks") or [])
        job = reply["jobId"]
        for _ in range(64):
            status, _headers, raw = http("%s/dsh-tts-api/rvc-next?job=%s" % (base, job), timeout=300)
            if status != 200:
                raise TtsError("rvc-next failed (status=%s)" % status)
            chunk = json.loads(raw.decode("utf-8", "replace"))
            if chunk.get("url"):
                urls.append(chunk["url"])
            if chunk.get("done") or not chunk.get("more", True):
                break
    else:
        raise TtsError("speak returned neither url nor jobId: %s" % reply)

    if not urls:
        raise TtsError("no audio urls came back")

    parts = []
    for index, url in enumerate(urls):
        status, _headers, audio = http(base + url if url.startswith("/") else url, method="GET", timeout=300)
        if status != 200 or len(audio) < 512:
            raise TtsError("fetching %s failed (status=%s, %d bytes)" % (url, status, len(audio)))
        part = os.path.join(workdir, "%s.part%02d.mp3" % (tag, index))
        with open(part, "wb") as handle:
            handle.write(audio)
        parts.append(part)

    if len(parts) == 1:
        shutil.move(parts[0], target)
    else:
        listing = os.path.join(workdir, "%s.concat.txt" % tag)
        with open(listing, "w", encoding="utf-8") as handle:
            for part in parts:
                # absolute: the concat demuxer resolves relative entries against
                # the list file's own directory, which would double the path
                handle.write("file '%s'\n" % os.path.abspath(part).replace("\\", "/").replace("'", "'\\''"))
        code, err = ffmpeg(["-f", "concat", "-safe", "0", "-i", listing, "-c", "copy", target])
        for part in parts:
            os.remove(part)
        os.remove(listing)
        if code != 0:
            raise TtsError("joining %d chunks failed: %s" % (len(parts), err[-300:]))
    return target, "%d chunk(s)" % len(parts)


def pad_to(source, target, seconds):
    """Extend a clip with silence to `seconds` (no-op when it is already longer)."""
    current = probe_duration(source) or 0.0
    if current >= seconds - 0.05:
        return source, current
    code, err = ffmpeg(["-i", source, "-af", "apad", "-t", "%.3f" % seconds,
                        "-c:a", "libmp3lame", "-b:a", "128k", "-ar", "24000", "-ac", "1", target])
    if code != 0:
        raise TtsError("padding %s failed: %s" % (source, err[-300:]))
    return target, probe_duration(target) or seconds


def concat(paths, target):
    listing = os.path.splitext(target)[0] + ".concat.txt"
    with open(listing, "w", encoding="utf-8") as handle:
        for path in paths:
            handle.write("file '%s'\n" % os.path.abspath(path).replace("\\", "/").replace("'", "'\\''"))
    code, err = ffmpeg(["-f", "concat", "-safe", "0", "-i", listing, "-c", "copy", target])
    os.remove(listing)
    if code != 0:
        raise TtsError("joining the narration track failed: %s" % err[-300:])
    return target


# --------------------------------------------------------------------- main ----
def normalize_argv(argv):
    """argparse refuses a value that looks like an option, and "-5%" is not a
    negative number to it, so `--rate -5%` needs rewriting to `--rate=-5%`."""
    out = []
    index = 0
    while index < len(argv):
        item = argv[index]
        if item == "--rate" and index + 1 < len(argv) and argv[index + 1].startswith("-"):
            out.append("--rate=%s" % argv[index + 1])
            index += 2
            continue
        out.append(item)
        index += 1
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("plan", nargs="?", help="plan JSON with scenes[].narration.script (not needed with --check)")
    parser.add_argument("--out", default="out/tts", help="where the per-scene mp3s land (default out/tts)")
    parser.add_argument("--clips", default="", help="folder of rendered clips, to align audio with footage")
    parser.add_argument("--base",
                        default=(os.environ.get("TTS_BASE_URL")
                                 or os.environ.get("DSH_WEB_URL")
                                 or "http://127.0.0.1:19387"),
                        help="base URL of the TTS route (default $TTS_BASE_URL, then $DSH_WEB_URL)")
    parser.add_argument("--voice", default="", help="voice name, e.g. zh-CN-XiaoxiaoNeural (default: plugin's)")
    parser.add_argument("--rate", default="", help="prosody rate, e.g. -5%% for calmer narration")
    parser.add_argument("--provider", default="edge-tts", help="edge-tts (default), rvc, index-tts2, cosyvoice, cloud")
    parser.add_argument("--only", default="", help="only scenes whose id contains this text")
    parser.add_argument("--pad", action="store_true",
                        help="pad each scene's audio to its clip length so one joined track stays in sync")
    parser.add_argument("--concat", default="", help="also write one track for assemble.py --audio here")
    parser.add_argument("--force", action="store_true", help="re-synthesise even when the mp3 already exists")
    parser.add_argument("--check", action="store_true", help="only test the route, then exit")
    parser.add_argument("--dry-run", action="store_true", help="list what would be spoken, synthesise nothing")
    args = parser.parse_args(normalize_argv(sys.argv[1:]))

    base = args.base.rstrip("/")
    if args.check:
        # route health only: no plan file required
        try:
            healthy, checks = diagnose(base)
        except TtsError as exc:
            print("tts       : %s" % exc)
            return 2
        print("route     : %s  (edge provider %s)" % (base, "ok" if healthy else "NOT ok"))
        for check in checks:
            print("            %-12s %s" % (check.get("id"), "ok" if check.get("ok") else "off"))
        return 0 if healthy else 2
    if not args.plan:
        parser.error("plan.json is required unless you only want --check")

    with open(args.plan, encoding="utf-8") as handle:
        plan = json.load(handle)
    scenes = {scene["id"]: scene for scene in plan.get("scenes", [])}
    order = plan.get("assembly", {}).get("order") or [scene["id"] for scene in plan.get("scenes", [])]
    order = [scene_id for scene_id in order if scene_id in scenes and (not args.only or args.only in scene_id)]

    if args.dry_run:
        for scene_id in order:
            script = (scenes[scene_id].get("narration", {}).get("script") or "").strip()
            print("%-9s %3d chars  ~%.1fs at 5 chars/s  %s"
                  % (scene_id, len(script), len(script) / 5.0, script[:48]))
        return 0

    try:
        healthy, checks = diagnose(base)
    except TtsError as exc:
        print("tts       : %s" % exc)
        print("hint      : point --base at a TTS route, or install one (see references/environment.md)")
        print("            no route is not a failure: build the .srt and ship subtitles only")
        return 2
    print("route     : %s  (edge provider %s)" % (base, "ok" if healthy else "NOT ok"))
    for check in checks:
        print("            %-12s %s" % (check.get("id"), "ok" if check.get("ok") else "off"))
    if not healthy:
        print("tts       : the edge provider is not answering; nothing synthesised")
        return 2

    os.makedirs(args.out, exist_ok=True)
    report = []
    failures = 0
    for scene_id in order:
        script = (scenes[scene_id].get("narration", {}).get("script") or "").strip()
        if not script:
            print("note      : %s has no narration script" % scene_id)
            continue
        try:
            path, how = speak(base, script, args.provider, args.voice, args.rate, args.out, scene_id, args.force)
        except TtsError as exc:
            print("FAIL %-9s %s" % (scene_id, exc))
            failures += 1
            report.append({"id": scene_id, "status": "failed", "error": str(exc)})
            continue

        audio = probe_duration(path)
        clip = None
        clip_path = os.path.join(args.clips, scene_id + ".mp4") if args.clips else ""
        if clip_path and os.path.exists(clip_path):
            clip = probe_duration(clip_path)
        drift = round(audio - clip, 2) if (audio and clip) else None

        padded = path
        if args.pad and clip:
            padded_path = os.path.join(args.out, scene_id + ".padded.mp3")
            try:
                padded, _length = pad_to(path, padded_path, clip)
            except TtsError as exc:
                print("note      : %s could not be padded (%s)" % (scene_id, exc))

        print("ok   %-9s %3d chars  audio %6.2fs  clip %s  %s  (%s)"
              % (scene_id, len(script), audio or 0.0,
                 ("%6.2fs" % clip) if clip else "   -   ",
                 ("drift %+.2fs" % drift) if drift is not None else "drift    -  ",
                 how))
        report.append({"id": scene_id, "status": "ok", "audio": path, "padded": padded,
                       "duration": audio, "clip_seconds": clip, "drift": drift, "chars": len(script),
                       "sha1": hashlib.sha1(script.encode("utf-8")).hexdigest()[:12]})

    if args.concat:
        paths = [entry["padded"] if (args.pad and entry.get("padded")) else entry["audio"]
                 for entry in report if entry["status"] == "ok"]
        if paths:
            try:
                concat(paths, args.concat)
                total = probe_duration(args.concat)
                print("track     : %s  %.2fs" % (args.concat, total or 0.0))
            except TtsError as exc:
                print("FAIL track: %s" % exc)
                failures += 1

    manifest = os.path.join(args.out, "tts-report.json")
    with open(manifest, "w", encoding="utf-8") as handle:
        json.dump({"base": base, "voice": args.voice, "rate": args.rate,
                   "provider": args.provider, "scenes": report}, handle, ensure_ascii=False, indent=2)
    print("report    : %s" % manifest)
    total_audio = sum(entry.get("duration") or 0 for entry in report if entry["status"] == "ok")
    print("summary   : %d synthesised, %d failed, %.1fs of speech"
          % (len(report) - failures, failures, total_audio))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
