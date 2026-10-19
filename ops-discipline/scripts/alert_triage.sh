#!/usr/bin/env bash
# alert_triage.sh — alert triage: list firing alerts and compare against the known-noise
# list (name + reason fingerprint + optional instance scope).
#
# Usage: KNOWN_FILE=<known-list-file> alert_triage.sh <command producing alert JSON...>
#
# Known-list format (one per line, TAB separated):
#   <alertname>                                        weak: any reason/instance passes
#   <alertname>\t<severity>\t<summary>                 strong: all three must match
#   <alertname>\t<severity>\t<summary>\t<instance>     strong+scoped: also bound to instance
#
# Parsing and classification are done entirely inside python3 (a HARD requirement):
# the JSON is decoded, validated, and compared structurally — no text round-trip, so
# U+001F or other control characters in fields cannot shift field boundaries. There is
# no lossy fallback: without a parser the answer is "insufficient evidence" (exit 1).
# Supported payloads: {"alerts":[...]} (status absent or "success"), Prometheus
# status/data/alerts envelope, Alertmanager v2 list (including the empty []), or a bare
# alert object.
#
# Exit codes: 0 = all known; 1 = no JSON parser; 2 = source failed / unsupported or
# unparsable payload; 3 = unknown or changed alert.
set -uo pipefail
KNOWN_FILE="${KNOWN_FILE:-/dev/null}"
if ! command -v python3 >/dev/null 2>&1; then
  echo "PARSER-MISSING: python3 is required for alert JSON decoding" >&2
  exit 1
fi
if ! out=$("$@"); then
  echo "ALERT-SOURCE-FAILED: command exited nonzero: $*" >&2
  exit 2
fi
printf '%s' "$out" | python3 -c '
import sys, json

known_file = sys.argv[1]

def load_known(path):
    strong = set(); weak = set()
    try:
        with open(path, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.rstrip("\r\n")   # tolerate CRLF known lists
                if not line or line.startswith("#"):
                    continue
                parts = line.split("\t")
                if len(parts) in (3, 4):
                    strong.add(tuple(parts))
                elif len(parts) == 1:
                    weak.add(parts[0])
                else:
                    print("KNOWN-LIST-INVALID: expected 1, 3, or 4 TAB-separated fields", file=sys.stderr)
                    sys.exit(2)
    except OSError:
        print("KNOWN-LIST-UNREADABLE: cannot load configured known list", file=sys.stderr)
        sys.exit(2)
    return strong, weak

raw = sys.stdin.read()
try:
    d = json.loads(raw)
except Exception:
    print("ALERT-PARSE-FAILED: payload is not valid JSON", file=sys.stderr)
    sys.exit(2)

if isinstance(d, list):
    alerts = d
elif isinstance(d, dict):
    if d.get("status") not in (None, "success"):
        print("ALERT-SOURCE-INVALID: envelope status is not success", file=sys.stderr)
        sys.exit(2)
    if isinstance(d.get("data"), dict):
        d = d["data"]
    alerts = d.get("alerts")
    if alerts is None:
        if isinstance(d.get("labels"), dict) and d["labels"].get("alertname"):
            alerts = [d]
        else:
            print("ALERT-PARSE-FAILED: no alert array or alert object", file=sys.stderr)
            sys.exit(2)
    if not isinstance(alerts, list):
        print("ALERT-PARSE-FAILED: alerts is not a list", file=sys.stderr)
        sys.exit(2)
else:
    print("ALERT-PARSE-FAILED: unsupported top-level type", file=sys.stderr)
    sys.exit(2)

strong, weak = load_known(known_file)
strong_names = {entry[0] for entry in strong}
unknown = 0
for a in alerts:
    if not isinstance(a, dict):
        print("ALERT-PARSE-FAILED: alert element is not an object", file=sys.stderr)
        sys.exit(2)
    labels = a.get("labels", {})
    ann = a.get("annotations", {})
    if not isinstance(labels, dict) or not isinstance(ann, dict):
        print("ALERT-PARSE-FAILED: labels and annotations must be objects", file=sys.stderr)
        sys.exit(2)
    fields = (labels.get("alertname", ""), labels.get("severity", ""),
              ann.get("summary", ""), labels.get("instance", ""))
    if not all(isinstance(value, str) for value in fields):
        print("ALERT-PARSE-FAILED: fingerprint fields must be strings", file=sys.stderr)
        sys.exit(2)
    name, sev, summary, inst = fields
    if not name:
        print("ALERT-PARSE-FAILED: alert element has no alertname", file=sys.stderr)
        sys.exit(2)
    detail = json.dumps(dict(name=name, instance=inst, severity=sev, summary=summary[:80]), ensure_ascii=False)
    print(f"ALERT: {detail}")
    if (name, sev, summary, inst) in strong or (name, sev, summary) in strong:
        continue
    if name in weak:
        continue
    kind = "CHANGED-REASON" if name in strong_names else "UNKNOWN-ALERT"
    print(f"{kind}: {detail}")
    unknown = 1
sys.exit(3 if unknown else 0)
' "$KNOWN_FILE"
rc=$?
if [ "$rc" = 3 ]; then
  exit 3
elif [ "$rc" = 0 ]; then
  exit 0
else
  exit 2
fi
