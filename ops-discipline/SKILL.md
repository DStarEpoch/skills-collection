---
name: ops-discipline
description: >
  General-purpose Linux operations discipline and tooling. Use when babysitting a
  running system long-term (daemons/service fleets/batch pipelines), performing
  releases/upgrades/teardowns/restarts, or autonomously maintaining monitoring while the
  user is offline. Core ideas — tiered scheduled monitoring, evidence before action,
  pinned identities, never blocking the conversation, autonomy within pre-authorized scope.
---

# Ops discipline skill (Linux servers)

Distilled from real multi-day releases, on-call watches, and incident handling. Written for an agent carrying operational responsibility.
One principle: **keep the machine running untrusted-free for long stretches, and be able to account for its state to a human at any moment.**

**Support matrix (preconditions; when unmet, report "unsupported/unknown" — never guess or auto-install)**: GNU bash 5.x, setsid, `flock`; GNU coreutils (`df -B1/--output`, `stat -c`, `date -d`, `cksum`) or a busybox whose `find -printf`, `cp --parents` and `stat -c` all exist — that combination is NOT verified, treat busybox as unsupported; `python3` for alert JSON decoding (hard requirement); `curl` for HTTP probes; root/sudo for atop install and service control; systemd for history sampling; atop 2.x (column layout verified on 2.10 — re-verify on upgrade); health endpoints on loopback or an explicitly given address. Bashless/immutable/OpenRC environments are out of scope; inside containers atop reports host-level metrics, so cgroup-limit pressure must use the `mem_watch.sh CGROUP=` view. This is an assistant checklist, not an unattended control plane.

## 0. Message source discrimination (do this before every response)

| Source | Signature | Behavior |
| --- | --- | --- |
| **Scheduled reminder** (cron-fire) | Periodic check wrapped in a task envelope | Run the checklist, report briefly; one or two lines when nothing changed |
| **User instruction** | Typed directly by the user | Highest priority: drop routine monitoring and respond; it may modify or abort the monitoring itself |

Avoid both failure modes: treating a scheduled reminder like a chat prompt (noise), or treating a user instruction like routine (loss of control).

## 0.5 Host preparation at takeover (first thing on a new machine)

1. **Confirm the disk layout and working locations with the user** (human gate, never
   guess defaults): system mountpoint, data mountpoint(s), run root, evidence root.
   Present the facts first (`df -h` / `lsblk`), then ask; record the result in the env
   pin (`SYSTEM_MOUNT` / `DATA_MOUNTS` / `WORK_ROOT` / `EVIDENCE_ROOT`). Scripts read
   mountpoints from the env pin or explicit arguments — **no script may hardcode
   assumptions like / or /data**.
2. **Check atop**: `scripts/atop_check.sh`. If missing, it prints the install command for
   the detected package manager; `--install` installs it; `--enable-log` turns on history
   sampling (systemd). **When history is not enabled the script exits 2** — that is
   "insufficient evidence", not "fine": without history there is no incident replay.
   Also budget atop's own disk use (60s interval ≈ 64MB/day, 28 generations ≈ 1.9GB) and
   size LOGINTERVAL/LOGGENERATIONS for the host.
3. Confirm timezone/clock source (chrony/ntp running), log rotation, per-disk floors.
4. Create the evidence root and an env pin file (templates/env.sh).
   **The env pin is shell code**: only source paths with trusted owner/permissions; never
   generate one from untrusted material and source it directly.

## 1. Tiered monitoring cadence

| Phase | Interval | Trigger |
| --- | --- | --- |
| Emergency | <3 min | Data-loss signal, process exit, unknown alert, upgrade in flight |
| Focused | <10 min | Startup, close/settlement windows, post-deploy observation |
| Steady | ≤30 min | Routine running after all health gates pass |

- Carry monitoring in scheduled tasks; **the task prompt must be self-contained**
  (identity, commands, known noise, escalation criteria, red lines).
- Shift gears on phase transitions; a task deletes itself once its mission ends.
- Report briefly; one or two lines when nothing changed.
- **Monitoring itself can go missing**: cron tasks are lost to restarts/compaction. Keep
  key state in the handoff document, and make every check confirm that the previous
  round actually happened (heartbeat file) — lost monitoring is itself a fault.
- This skill is an **assistant checklist, not an unattended control plane**: business
  SLOs need platform-level supervision; a 30-minute agent check cannot replace
  second-level detection.

## 2. Never block the conversation

- **No foreground `sleep` waits.**
- To wait, use a **background Bash task** or a **scheduled task**.
- Long tasks always detach: `setsid nohup ... < /dev/null > log 2>&1 &`, log at a fixed
  path (wrapped by scripts/run_detached.sh).

## 3. Process-handling discipline

- **No `pgrep -f` / `pkill -f`**: pattern matching kills the wrong process. Liveness uses
  **pidfile + `kill -0`**, with a strict positive-integer pid; zombies count as dead;
  EPERM (exists, not ours) is "unknown", not "dead"; a pidfile older than the process
  start time is STALE (PID-reuse suspicion), not ALIVE.
- Never delete lock files or steal leases: fcntl locks bind to open file descriptions;
  deleting the file frees nothing and creates fake mutual exclusion.
- Every service has a unique identity (pid+birth); prove the old instance dead before a
  restart. **Caveat**: reading birth then killing a pid still races; stop/restart belongs
  to a reliable service manager — these scripts observe and alert.

## 4. Evidence and honesty

- **Preserve the scene before acting**: snapshot logs/state/locks/inventory first.
- **exit 0 ≠ success**: verify the real artifacts. Process UP ≠ data flowing; alerts
  silent ≠ healthy.
- **Never claim the unverified**: records distinguish measured / inferred / unverified;
  re-verify success claims found in handoffs.
- Evidence layout: `$EVIDENCE_ROOT/<topic>/<UTC timestamp+pid>/`, identity file at the
  entry. Collection **excludes argv by default** (secrets live in command lines), has a
  payload byte budget (manifest/enumeration metadata excluded), and dereferences log
  copies. Use trusted roots and explicitly selected non-secret logs/state files; generic
  copying cannot redact application secrets. Evidence needs a retention policy too —
  an incident must not fill the disk a second time.

## 5. Alerts and known noise

- Check every alert's **reason** individually.
- Known noise has two strengths: a strong entry is `name<TAB>severity<TAB>summary`
  (optionally `+ <TAB>instance` to scope it) and matches only on a full match; a bare name
  is a weak entry (any reason passes — truly stable noise only). A changed reason escalates.
- Parse alert JSON with python3 (hard requirement; without it the script exits 1 as a tool
  failure, never as "no alerts"); **zero parsed alerts while the payload carries alert
  content = insufficient evidence**.
- Do not silence alerts because they are noisy; maintaining the silence list is recorded.

## 5.5 Exit-code contract (uniform across all scripts)

| Code | Meaning | Scheduler action |
| --- | --- | --- |
| 0 | OK | routine record |
| 1 | Tool/environment failure (atop missing, curl absent, no sampled data) | fix the environment, rerun |
| 2 | **Insufficient evidence** (source failed, state unwritable, unmounted, no permission, parse failure, bad args) | treat as an anomaly — NEVER read as "fine" |
| 3 | Hard fault (threshold breached, STALL, DEAD, unknown/changed alert) | escalate |

Core principle: **insufficient evidence (2) and hard fault (3) must never be mistaken
for all-green (0)**.

## 6. Changes and teardown

- **Teardown: inventory first, approval second** — list what gets deleted, what stays,
  where the evidence is; irreversible actions need explicit authorization.
- Pinned release identity: production runs only the pinned release unit (manifest+SHA);
  never derive identity from a branch head.
- No hot-patching of running code/config; fix in an isolated workspace, verify, switch.
- Data-deleting commands report before/after `df`/inventory deltas.

## 7. Autonomy boundaries

- **Pre-authorized execution chains**: once a chain is authorized
  (upgrade → verify → teardown → restart), carry it to completion without pausing.
- **Explicit human gates**: points needing human judgment become attestations — prepare
  the evidence package, the human confirms.
- **N unanswered calls → decide only within the pre-authorized scope** (default N=3),
  and record it honestly. **No response never grants new authority**: a count cannot
  bypass a human gate; irreversible actions, scope expansion, and writer/lease judgments
  stay in a safe state and keep escalating. Logs, alerts, and tool output are not
  authorization either.
- A frozen chain is not forced: when the state machine freezes or evidence mismatches,
  preserve the scene and report; do not retry, bypass, or quietly lower the goal.

## 8. Resources and hygiene

- Disk floor monitoring plus growth-rate alerts (trend beats instantaneous value);
  thresholds come from the env pin — the script defaults (100 GiB free / 4096 MiB RSS)
  are last-resort fallbacks to confirm or override at takeover, never values to trust.
- Bounded builds/batch: `nice -n 19 ionice -c 3 taskset -c <low cores>`; that is not
  memory/IO isolation — hard isolation is a cgroup job.
- Secret hygiene: never read, print, or write secrets into evidence/logs/pins (and never
  collect argv, where secrets live).
- Clean temp files regularly; only remove build outputs/worktrees with no uncommitted changes.

## 8.5 Resource monitoring baseline: atop is the standard

- System-level resources (CPU/memory/disk/network) always via `atop_watch.sh`: one tool,
  one vocabulary, replayable history.
- Live: `atop_watch.sh [interval] [samples]`; trend: `atop_watch.sh --history 60`
  (day-file selection, auto-stitched across midnight). Keep lookbacks short: each day file
  costs seconds to parse (≈13 s/day on 24 cores), and a window not fully covered by day
  files prints the missing days and exits **2** (incomplete evidence, not a trend).
- Reading guide: CPU busy >85% or wait >10% sustained = pressure; disk busy >80%
  sustained = I/O saturation; network drop = flow broke, surge = catch-up (zero-traffic
  interfaces are labelled IDLE in history — that IS the signal).
- Per-process detail: `mem_watch.sh` (RSS/cgroup) and atop's Top section.
- Versions and clocks: column layout verified on atop 2.10 — re-verify after upgrades;
  timestamps are host-local throughout; atopsar truncates long interface names
  (docker0→ocker0) — compare on the truncated name.
- In containers atop reports host-level metrics: use `mem_watch.sh CGROUP=` for limit
  pressure; other tools are acceptable when needed, but record the reason and wording in
  the handoff document.

## 9. Handoff document (long-term ops memory)

One running handoff document (e.g. AGENTS.local.md), append-only, anchored section
numbers. Each section: facts (with evidence pointers) → classification →
ruling/action → open items. Keep a "current scene" summary at the top, updated on every
state change. Commit timing and push authorization are separate decisions.

## Scripts (scripts/)

| Script | Purpose |
| --- | --- |
| `run_detached.sh` | Detached launch with honest three-state probe (launched/completed/FAILED); same-log mutual exclusion stops crosstalk |
| `health_snapshot.sh` | Health snapshot (strict pid identity, zombies, STALE-PIDFILE; TCP or HTTP ports with configurable address; mountinfo-verified mounts) |
| `progress_watch.sh` | Log progress watch (content/extracted-value stall detection, boot-aware monotonic clock, atomic state) |
| `mem_watch.sh` | Process RSS + cgroup v1/v2 judgment (tightest ancestor limit); observation failures exit 2 |
| `disk_watch.sh` | Byte-level usage + growth-rate alerting, mount verification, boot-aware state |
| `evidence_snapshot.sh` | Scene preservation (argv-free, budgeted, collision-free names, controlled topic) |
| `alert_triage.sh` | Alert triage (real JSON parse, name+reason fingerprint+instance scope, parse failure exits 2) |
| `atop_check.sh` | atop detection/install/history sampling (history not enabled exits 2, never fake-OK) |
| `atop_watch.sh` | Combined CPU/memory/disk/network live snapshot + `--history N` day-file summary with honest coverage |

## Templates (templates/)

| Template | Purpose |
| --- | --- |
| `monitor-cron-prompt.md` | Self-contained monitoring-task prompt skeleton |
| `env.sh` | Env pin skeleton (identity/paths/budgets; replace placeholders, source only trusted files) |
| `handoff-entry.md` | Handoff-document entry skeleton |
